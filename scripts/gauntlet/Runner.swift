#!/usr/bin/swift
// Phase 1 orchestration only. This CLI intentionally does not launch UI tests.
import Foundation
import Darwin

let fm = FileManager.default
let stageOrder = ["unit", "regression", "integration", "performance", "hallie", "stress", "ui"]
var interrupted: Int32 = 0
func onSignal(_ value: Int32) { interrupted = value }
func monotonic() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
struct RunError: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) }
func readObject(_ path: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else { throw RunError("invalid JSON object: \(path.path)") }
    return object
}
// Resolve existing ancestors too: appending a not-yet-created child to a symlink
// must not turn the checked lexical path into permission to write elsewhere.
func canonicalPath(_ url: URL) throws -> String {
    var existing = url.path
    var suffix: [String] = []
    while !fm.fileExists(atPath: existing) {
        suffix.insert(URL(fileURLWithPath: existing).lastPathComponent, at: 0)
        let parent = URL(fileURLWithPath: existing).deletingLastPathComponent().path
        guard parent != existing else { throw RunError("cannot resolve write path") }
        existing = parent
    }
    guard let resolved = realpath(existing, nil) else { throw RunError("cannot canonicalize write path") }
    defer { free(resolved) }
    return ([String(cString: resolved)] + suffix).joined(separator: "/")
}
func guarded(_ path: URL, under root: URL) throws -> URL {
    let canonicalRoot = try canonicalPath(root)
    let canonical = try canonicalPath(path)
    guard canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/") else { throw RunError("write allowlist refused: \(path.path)") }
    guard canonical == path.path else { throw RunError("symlink write escape refused: \(path.path)") }
    return URL(fileURLWithPath: canonical)
}
func write(_ data: Data, to path: URL, root: URL) throws {
    let safe = try guarded(path, under: root)
    try data.write(to: safe, options: .atomic)
}
/// Appends with O_APPEND: the kernel places each write(2) at the end of the
/// file at the moment of the write, so two runners appending to one
/// history.jsonl never overwrite each other's row (Codex sweep 11/09 F3; the
/// old seek-to-end + write let a second writer land on the first's bytes).
func append(_ data: Data, to path: URL, root: URL, sync: Bool = false, syncer: (Int32) -> Int32 = { fsync($0) }) throws {
    let safe = try guarded(path, under: root)
    let fd = open(safe.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd >= 0 else { throw RunError("cannot open \(safe.path) for append: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    // One writer at a time for the whole record, so a short write can never
    // let another runner's row land inside this one (re-review N4); the lock
    // is released when fd closes (≈ a scoped std::lock_guard on the file).
    guard flock(fd, LOCK_EX) == 0 else { throw RunError("lock \(safe.path): \(String(cString: strerror(errno)))") }
    // A torn last line (a crash mid-append) is sealed with a newline first,
    // so this row is never glued onto it (re-review N3).
    // The tail must be known: a tail that cannot be read is refused rather
    // than risk gluing this row onto a torn one (closing pass G2).
    var data = data
    var st = stat()
    guard fstat(fd, &st) == 0 else { throw RunError("stat \(safe.path): \(String(cString: strerror(errno)))") }
    let sizeBefore = st.st_size
    if sizeBefore > 0 {
        var last: UInt8 = 0
        guard pread(fd, &last, 1, sizeBefore - 1) == 1 else { throw RunError("read the tail of \(safe.path): \(String(cString: strerror(errno)))") }
        if last != 0x0A { data.insert(0x0A, at: 0) }
    }
    do {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw RunError("append \(safe.path): \(String(cString: strerror(errno)))") }
                offset += n
            }
        }
        if sync, syncer(fd) != 0 { throw RunError("fsync \(safe.path): \(String(cString: strerror(errno)))") }
    } catch {
        // A row that is not durable must not stay visible — a retention
        // reader would take it as the run's summary (closing pass G1). Roll
        // the file back to its size before this append (still under the lock).
        _ = ftruncate(fd, sizeBefore)
        throw error
    }
}
struct CommandResult { var code: Int32; var timedOut = false; var contaminated = false; var elapsed: Double }
// Same ownership protocol as nightly_local_tests.sh: private process group,
// retain the unreaped leader throughout TERM/grace/KILL to reserve its PGID.
// posix_spawn is used here because Foundation Process cannot atomically set PGID.
func command(_ arguments: [String], log: URL, timeout: Double, environment: [String: String]? = nil) throws -> CommandResult {
    let start = monotonic()
    guard log.path == (try canonicalPath(log)) else { throw RunError("symlink command log refused") }
    let fd = open(log.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw RunError("cannot open command log") }
    defer { close(fd) }
    var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, fd)
    var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP)); posix_spawnattr_setpgroup(&attr, 0)
    let argStrings = arguments.map { strdup($0) }
    let envStrings = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
    defer { argStrings.forEach { free($0) }; envStrings.forEach { free($0) } }
    var argv = argStrings + [nil]; var envp = envStrings + [nil]; var pid: pid_t = 0
    let launched = posix_spawnp(&pid, arguments[0], &actions, &attr, &argv, &envp)
    guard launched == 0 else { throw RunError("spawn \(arguments[0]): \(String(cString: strerror(launched)))") }
    var status: Int32 = 0
    var orphanedDescendants = false
    while monotonic() - start < timeout && interrupted == 0 {
        var information = siginfo_t()
        let found = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if found == 0 && information.si_pid == pid {
            // Keep the exited leader reserved until its group is empty. A
            // daemonized child still in this group must not overlap a stage.
            if kill(-pid, 0) == 0 { orphanedDescendants = true; break }
            guard waitpid(pid, &status, WNOHANG) == pid else { throw RunError("could not reap exited leader") }
            let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            return CommandResult(code: code, elapsed: monotonic() - start)
        }
        if found < 0 && errno != EINTR { throw RunError("waitpid failed") }
        usleep(100_000)
    }
    let timeoutReached = interrupted == 0 && !orphanedDescendants
    _ = kill(-pid, SIGTERM)
    usleep(500_000)
    _ = kill(-pid, SIGKILL)
    let end = monotonic() + 1
    while kill(-pid, 0) == 0 && monotonic() < end { usleep(10_000) }
    let alive = kill(-pid, 0) == 0
    let reaped = alive ? false : waitpid(pid, &status, WNOHANG) == pid
    return CommandResult(code: orphanedDescendants ? 125 : timeoutReached ? 124 : 128 + interrupted, timedOut: timeoutReached, contaminated: !reaped || orphanedDescendants, elapsed: monotonic() - start)
}
func capture(_ arguments: [String]) -> String {
    let pipe = Pipe(); let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = arguments
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" } catch { return "" }
}
func classify(exitCode: Int32, counts: [String: Int]?, floor: Int) -> (String, String?) {
    if exitCode != 0 { return ("failed", "command exit \(exitCode)") }
    guard let counts else { return ("failed", "structured test counts unavailable") }
    if counts["failed", default: 0] > 0 { return ("failed", "test failures") }
    if counts["skipped", default: 0] > 0 { return ("failed", "unexpected skipped tests") }
    let known = counts["known_issues", default: 0]
    if counts["passed", default: 0] + counts["failed", default: 0] + known < max(1, floor) { return ("failed", "executed count below expected floor \(max(1, floor))") }
    // A withKnownIssue is a tracked bug, never a pass — and never a failure
    // either: AMBER (Rick 2026-11-05, DECISIONS). Said by name and count.
    if known > 0 { return ("amber", "\(known) known issue\(known == 1 ? "" : "s") (withKnownIssue) — tracked, not a pass") }
    return ("passed", nil)
}
func countsFromSummary(_ object: [String: Any]) -> [String: Int]? {
    guard let passed = object["passedTests"] as? Int, let failed = object["failedTests"] as? Int, let skipped = object["skippedTests"] as? Int else { return nil }
    guard passed >= 0 && failed >= 0 && skipped >= 0 else { return nil }
    let known = object["expectedFailures"] as? Int ?? 0
    guard known >= 0, let total = object["totalTestCount"] as? Int, total == passed + failed + skipped + known,
          let verdict = object["result"] as? String, ["Passed", "Failed", "Skipped"].contains(verdict),
          verdict != "Failed" || failed > 0 else { return nil }
    return ["passed": passed, "failed": failed, "skipped": skipped, "known_issues": known]
}
// The package adapter's counts (2026-11-05). The console is for humans: a
// concurrent test's stdout can split a result line (M4 deep run at 2c8fa9777
// counted 774 of 775) or forge one. Swift Testing is counted from its event
// stream (`swift test --event-stream-output-path`: one JSON record a line,
// written by the testing library to its own file, so test stdout never
// touches it); XCTest from the console, because `swift test` writes no XCTest
// xunit in serial mode (6.4: --xunit-output yields only -swift-testing.xml) —
// read as the runner's serial PROTOCOL (XCTestConsoleTally) and cross-checked
// against `swift test list` (`xctestList`, its stdout; nil = the list could
// not be produced) narrowed by the run's own `--filter` regexes (`filters`):
// SwiftPM 6.4's `list` accepts --filter and ignores it, printing the whole
// package (M4 gauntlet 2026-11-06 went RED on every filtered stage until the
// filters were applied here). Codex 11/05: a body printing a
// result line, then a whole forged bracket + summary, inflated the count; a
// filtered run's bracket is "Selected tests". Counts that disagree are nil =
// unavailable (a RED stage), never inflated, never silently zero. One count
// per test function (a parameterized test is one, its cases are not), the
// same unit the floors are declared in. nil also for: no runEnded, a torn
// record, an event for an undeclared id.
// Memory: the files are read whole; ~6 records per test, ~300 B each, so a
// 1,000-test stage is ~2 MB and the 20k-test scale sensor ~40 MB.
func countsFromPackageRun(eventStream: String, console: String, xctestList: String?, filters: [String]) -> [String: Int]? {
    guard var counts = SwiftTestingTally(eventStream: eventStream)?.counts,
          let xctest = XCTestConsoleTally(console: console, selected: xctestList.flatMap { selectedXCTests($0, filters: filters) }) else { return nil }
    for (key, value) in xctest.counts { counts[key, default: 0] += value }
    return counts
}

/// Names for the summary row from the same two sources, read leniently (a
/// killed run still names its failures and the tests left without a verdict).
func packageNames(eventStream: String, console: String, xctestList: String?, filters: [String]) -> TestNames {
    var names = SwiftTestingTally(eventStream: eventStream, lenient: true)?.names ?? TestNames()
    names.merge(XCTestConsoleTally.names(console: console, selected: xctestList.flatMap { selectedXCTests($0, filters: filters) }))
    return names
}

/// The XCTest methods in `swift test list` output that the run's `--filter`
/// regexes select, as the console names them ("Module.Class method"). XCTest
/// lists as `Module.Class/method`; Swift Testing as `Module.Suite/name()`
/// (parentheses) — not XCTest, not counted here. The filter semantics are
/// SwiftPM's for XCTest (`TestCaseSpecifier.regex`): a test is selected when
/// ANY pattern matches anywhere in `Module.Class/method` (unanchored ICU
/// search, as `String.range(of:options: .regularExpression)`); no filters
/// selects all. nil = a pattern that does not compile (selection unknowable,
/// so counts unavailable — never "nothing selected").
func selectedXCTests(_ list: String, filters: [String]) -> Set<String>? {
    let xctest = try! NSRegularExpression(pattern: #"^([^\s/()]+)/([^\s/()]+)$"#)
    var patterns: [NSRegularExpression] = []
    for filter in filters {
        guard let re = try? NSRegularExpression(pattern: filter) else { return nil }
        patterns.append(re)
    }
    var out = Set<String>()
    for raw in list.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let whole = NSRange(line.startIndex..., in: line)
        guard let m = xctest.firstMatch(in: line, range: whole) else { continue }
        guard patterns.isEmpty || patterns.contains(where: { $0.firstMatch(in: line, range: whole) != nil }) else { continue }
        out.insert((line as NSString).substring(with: m.range(at: 1)) + " " + (line as NSString).substring(with: m.range(at: 2)))
    }
    return out
}

/// XCTest outcomes from the serial protocol the XCTest runner prints, held to
/// an independent list of what was selected (`swift test list`):
///   • the bracket is the FIRST "Test Suite 'All|Selected tests' started" to
///     the LAST "… passed|failed at" (a body can print a close; the runner's
///     comes after it), and the runner's summary is the first "Executed N
///     tests, with S skipped" after that last close;
///   • inside it, a result line counts only for the test the runner last
///     "started"; the LAST result for that test wins (the real line follows
///     the body); a "started" for a test already judged, or while another is
///     open, is a print, not the runner;
///   • the tally must name exactly the selected XCTest methods, and the
///     runner's summary must agree with it (total and skipped), else nil:
///     counts unavailable, RED — never inflated;
///   • no bracket at all is zeros only when nothing XCTest was selected;
///     selected tests with no XCTest phase are unavailable, never silently 0.
/// Residual: a body that forges its own result AND the next test's "started"
/// can mislabel itself (never add a test), and the stage still fails on
/// `swift test`'s exit code, which XCTest sets itself.
/// C++ analogy: a small state machine over lines; `nil` is the poisoned state.
struct XCTestConsoleTally {
    private(set) var outcomes: [String: String] = [:]                 // "M.X testA" -> passed/failed/skipped
    private(set) var executed: (total: Int, skipped: Int)?            // the runner's own summary
    private(set) var sawBracket = false

    private static let started = try! NSRegularExpression(pattern: #"Test Case '-\[([^\]]+)\]' started\."#)
    private static let result = try! NSRegularExpression(pattern: #"Test Case '-\[([^\]]+)\]' (passed|failed|skipped) \("#)
    private static let opens = try! NSRegularExpression(pattern: #"Test Suite '(All|Selected) tests' started at "#)
    private static let closes = try! NSRegularExpression(pattern: #"Test Suite '(All|Selected) tests' (passed|failed) at "#)
    private static let summary = try! NSRegularExpression(pattern: #"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?\d+ failures?"#)

    private static func match(_ re: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    /// `selected`: the XCTest methods listed for this run's filter, or nil when
    /// the list could not be produced (no cross-check → no count).
    init?(console: String, selected: Set<String>?) {
        guard let selected else { return nil }
        let lines = console.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let openAt = lines.firstIndex(where: { Self.match(Self.opens, $0) != nil }) else {
            guard selected.isEmpty else { return nil }                  // selected, but no XCTest phase ran
            return                                                      // nothing XCTest selected: zeros
        }
        sawBracket = true
        guard let closeAt = lines.lastIndex(where: { Self.match(Self.closes, $0) != nil }), closeAt > openAt else { return nil }
        outcomes = Self.scan(lines[(openAt + 1)..<closeAt]).outcomes
        guard let summaryLine = lines[(closeAt + 1)...].first(where: { Self.match(Self.summary, $0) != nil }),
              let m = Self.match(Self.summary, summaryLine) else { return nil }
        let total = Int((summaryLine as NSString).substring(with: m.range(at: 1))) ?? -1
        let skippedRange = m.range(at: 2)
        let skipped = skippedRange.location == NSNotFound ? 0 : Int((summaryLine as NSString).substring(with: skippedRange)) ?? -1
        executed = (total, skipped)
        guard Set(outcomes.keys) == selected, total == outcomes.count,
              skipped == outcomes.values.filter({ $0 == "skipped" }).count else { return nil }
    }

    /// The started/result protocol over `lines`; `open` = a test started and never judged.
    private static func scan(_ lines: ArraySlice<String>) -> (outcomes: [String: String], open: String?) {
        var outcomes: [String: String] = [:]
        var open: String?
        for line in lines {
            if let m = match(started, line) {
                let id = (line as NSString).substring(with: m.range(at: 1))
                // The runner starts the next test only after judging the open one.
                if outcomes[id] == nil, open.map({ outcomes[$0] != nil }) ?? true { open = id }
            } else if let m = match(result, line) {
                let id = (line as NSString).substring(with: m.range(at: 1))
                if id == open { outcomes[id] = (line as NSString).substring(with: m.range(at: 2)) }   // last wins
            }
        }
        return (outcomes, open.flatMap { outcomes[$0] == nil ? $0 : nil })
    }

    /// Names for the summary row, leniently: a killed run (no closing bracket)
    /// still names what failed, and every selected test without a verdict is
    /// incomplete. Names only; counts stay with the strict init above.
    static func names(console: String, selected: Set<String>?) -> TestNames {
        let lines = console.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let openAt = lines.firstIndex(where: { match(opens, $0) != nil })
        let scanned = scan(openAt.map { lines[($0 + 1)...] } ?? lines[...])
        let slash = { (id: String) in id.replacingOccurrences(of: " ", with: "/") }   // "M.X testA" -> "M.X/testA"
        var names = TestNames()
        for (id, outcome) in scanned.outcomes where outcome != "passed" {
            if outcome == "failed" { names.failed.insert(slash(id)) } else { names.skipped.insert(slash(id)) }
        }
        let unjudged = (selected ?? []).subtracting(scanned.outcomes.keys).union(scanned.open.map { [$0] } ?? [])
        names.incomplete.formUnion(unjudged.map(slash))
        return names
    }

    var counts: [String: Int] {
        ["passed": outcomes.values.filter { $0 == "passed" }.count,
         "failed": outcomes.values.filter { $0 == "failed" }.count,
         "skipped": outcomes.values.filter { $0 == "skipped" }.count]
    }
}

/// Swift Testing outcomes per function id, from one event stream. Sets, so a
/// repeated event never double counts (like a std::set keyed by test id).
struct SwiftTestingTally {
    var kinds: [String: String] = [:]                                  // id -> "function" / "suite"
    var ended = Set<String>(), skipped = Set<String>(), failed = Set<String>(), known = Set<String>()
    var unattributedFailures = 0

    /// nil = unavailable: a torn record, an event for an undeclared id, no runEnded.
    /// `lenient` (names only, never counts): skip what strict refuses, so a
    /// killed run still names its failures and its unfinished tests.
    init?(eventStream: String, lenient: Bool = false) {
        var events: [[String: Any]] = []
        for line in eventStream.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { if lenient { continue }; return nil }
            if object["kind"] as? String == "test", let id = payload["id"] as? String { kinds[id] = payload["kind"] as? String ?? "" }
            if object["kind"] as? String == "event" { events.append(payload) }
        }
        var sawRunEnded = false
        for payload in events {
            if payload["kind"] as? String == "runEnded" { sawRunEnded = true; continue }
            guard record(payload) || lenient else { return nil }
        }
        guard sawRunEnded || lenient else { return nil }
    }

    /// The stream declares only the run's selected functions (checked against
    /// swift 6.4, 2026-11-08), so declared minus judged = incomplete.
    var names: TestNames {
        let functions = Set(kinds.filter { $0.value == "function" }.keys)
        var names = TestNames()
        names.failed = Set(failed.map(Self.display))
        names.skipped = Set(skipped.subtracting(failed).map(Self.display))
        names.incomplete = Set(functions.subtracting(ended).subtracting(skipped).subtracting(failed).map(Self.display))
        return names
    }

    /// "M.S/name()/T.swift:12:4" -> "M.S/name()": the source location is noise in a summary.
    static func display(_ id: String) -> String {
        id.replacingOccurrences(of: #"/[^/]+\.swift:\d+:\d+$"#, with: "", options: .regularExpression)
    }

    /// Fold one event in; false when it names a test the stream never declared.
    mutating func record(_ payload: [String: Any]) -> Bool {
        let id = payload["testID"] as? String
        if let id, kinds[id] == nil { return false }
        guard let id, kinds[id] == "function" else {
            // Not a function (suite / run level): only a failure matters, and it is RED.
            if Self.isFailure(payload) { unattributedFailures += 1 }
            return true
        }
        switch payload["kind"] as? String ?? "" {
        case "issueRecorded":
            if Self.isFailure(payload) { failed.insert(id) } else if (payload["issue"] as? [String: Any])?["isKnown"] as? Bool == true { known.insert(id) }
        case "testEnded": ended.insert(id)
        case "testSkipped": skipped.insert(id)
        case "testCancelled", "testCaseCancelled": failed.insert(id)       // cancelled is not a pass
        default: break
        }
        return true
    }

    /// A failing issue or a cancel. Stream v0 has no isFailure: any issue not known fails there.
    static func isFailure(_ payload: [String: Any]) -> Bool {
        switch payload["kind"] as? String ?? "" {
        case "testCancelled", "testCaseCancelled": return true
        case "issueRecorded":
            let issue = payload["issue"] as? [String: Any] ?? [:]
            return !(issue["isKnown"] as? Bool ?? false) && (issue["isFailure"] as? Bool ?? true)
        default: return false
        }
    }

    /// A failure wins over a known issue; a failure counts ended or not.
    var counts: [String: Int] {
        let knownOnly = ended.subtracting(failed).intersection(known)
        return ["passed": ended.subtracting(failed).subtracting(knownOnly).subtracting(skipped).count,
                "failed": failed.count + unattributedFailures,
                "skipped": skipped.subtracting(failed).count, "known_issues": knownOnly.count]
    }
}
func stageResult(_ name: String, _ status: String, _ reason: String?, floor: Int = 0) -> [String: Any] {
    let row: [String: Any] = ["name": name, "status": status, "reason": reason as Any? ?? NSNull(), "exit_code": NSNull(), "elapsed_s": 0.0, "expected": floor, "passed": NSNull(), "failed": NSNull(), "skipped": NSNull(), "incomplete": status == "passed" ? 0 : 1, "artifacts": []]
    return row.merging(TestNames().fields) { $1 }
}

// MARK: The summary row (Rick 2026-11-08)
// "13,000 passed, 12 failed, 2 unknown <list of fails> date/time/machine,
// nothing else is needed": once the run dir is deleted, the history.jsonl row
// is the only record. It names failed / unexpectedly skipped / incomplete
// tests per stage, from the same sources the counts come from (xcresult
// summary, the package event stream and XCTest protocol), and says what
// started failing and what was fixed since the previous row for the machine.
// Memory: each list is capped at `nameCap`; a row is a few KB (was ~140 KB,
// mostly blocked_details); history.jsonl is streamed one line at a time.
let nameCap = 200

/// Test names by outcome for one stage (sets, so duplicates never inflate).
struct TestNames {
    var failed = Set<String>(), skipped = Set<String>(), incomplete = Set<String>()

    mutating func merge(_ other: TestNames) {
        failed.formUnion(other.failed); skipped.formUnion(other.skipped); incomplete.formUnion(other.incomplete)
    }

    /// failed_tests / skipped_tests / incomplete_tests (sorted, first 200) and their `_truncated` counts.
    var fields: [String: Any] {
        var out: [String: Any] = [:]
        for (key, names) in [("failed_tests", failed), ("skipped_tests", skipped), ("incomplete_tests", incomplete)] {
            let sorted = names.sorted()
            out[key] = Array(sorted.prefix(nameCap)); out[key + "_truncated"] = max(0, sorted.count - nameCap)
        }
        return out
    }
}

/// Failed names from the xcresult summary the counts already come from; skipped
/// names from `xcresulttool get test-results tests` (the summary has none),
/// read only when the summary says something was skipped.
func xcodeNames(summary: [String: Any]?, tests: Any?) -> TestNames {
    var names = TestNames()
    for failure in summary?["testFailures"] as? [[String: Any]] ?? [] {
        let target = (failure["targetName"] as? String).map { $0 + "/" } ?? ""
        if let id = failure["testIdentifierString"] as? String ?? (failure["testName"] as? String).map({ target + $0 }) { names.failed.insert(id) }
    }
    func walk(_ node: Any) {
        if let list = node as? [Any] { list.forEach(walk); return }
        guard let dict = node as? [String: Any] else { return }
        if dict["nodeType"] as? String == "Test Case", dict["result"] as? String == "Skipped",
           let id = dict["nodeIdentifier"] as? String ?? dict["name"] as? String { names.skipped.insert(id) }
        if let children = dict["testNodes"] ?? dict["children"] { walk(children) }
    }
    if let tests { walk(tests) }
    return names
}

/// Each history.jsonl row in turn, one line in memory at a time (like a getline loop in C).
/// `terminatedOnly`: skip a last line with no newline — an append that never
/// finished is not a durable row (Codex sweep 11/09 re-review N3).
func forEachHistoryRow(_ history: URL, terminatedOnly: Bool = false, _ body: ([String: Any]) -> Void) {
    guard let file = fopen(history.path, "r") else { return }
    defer { fclose(file) }
    var buffer: UnsafeMutablePointer<CChar>?; var capacity = 0
    defer { free(buffer) }
    while true {
        let n = getline(&buffer, &capacity, file)
        guard n > 0, let buffer else { break }
        if terminatedOnly, buffer[n - 1] != 0x0A { continue }
        guard let row = try? JSONSerialization.jsonObject(with: Data(String(cString: buffer).utf8)) as? [String: Any] else { continue }
        body(row)
    }
}

/// The last row written for `machine`, or nil (none yet).
func previousRow(history: URL, machine: String) -> [String: Any]? {
    var last: [String: Any]?
    forEachHistoryRow(history) { if $0["machine"] as? String == machine { last = $0 } }
    return last
}

func historyHasRun(_ history: URL, runID: String) -> Bool {
    var found = false
    forEachHistoryRow(history, terminatedOnly: true) { if $0["run_id"] as? String == runID { found = true } }
    return found
}

/// Pure: what started failing, what was fixed, and since when each failure has
/// been failing, against `previous` (the last row for this machine). A test is
/// "fixed" only when its stage ran with counts this time and it is neither
/// failing, skipped nor incomplete now: a stage that did not run fixes nothing.
func failureChanges(current: [String: Any], previous: [String: Any]?) -> [String: Any] {
    let list = { (stage: [String: Any], key: String) in Set(stage[key] as? [String] ?? []) }
    let stages = current["stages"] as? [[String: Any]] ?? []
    let before = Dictionary((previous?["stages"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", list($0, "failed_tests")) }) { $0.union($1) }
    let since = previous?["first_failed"] as? [String: String] ?? [:]
    let ts = current["ts"] as? String ?? ""
    var newFailures = Set<String>(), fixed = Set<String>(), firstFailed: [String: String] = [:]
    for stage in stages {
        let name = stage["name"] as? String ?? ""
        let failing = list(stage, "failed_tests")
        let wasFailing = before[name] ?? []
        for test in failing {
            if wasFailing.contains(test) { firstFailed[test] = since[test] ?? previous?["ts"] as? String ?? ts } else { newFailures.insert(test); firstFailed[test] = ts }
        }
        // No evidence, no "fixed" (Codex sweep 11/09 F5): a stage whose name
        // lists were truncated, or a run whose package build failed (its
        // tests supplied no names), proves nothing about a missing name.
        let truncated = ["failed_tests", "skipped_tests", "incomplete_tests"].contains { (stage[$0 + "_truncated"] as? Int ?? 0) > 0 }
        let packageBuildFailed = (current["package_build_exit_code"] as? NSNumber).map { $0.intValue != 0 } ?? false
        if stage["passed"] is NSNumber, !truncated, !packageBuildFailed {
            fixed.formUnion(wasFailing.subtracting(failing).subtracting(list(stage, "skipped_tests")).subtracting(list(stage, "incomplete_tests")))
        }
    }
    return ["compared_to": previous?["run_id"] ?? NSNull(), "new_failures": newFailures.sorted(), "fixed": fixed.sorted(), "first_failed": firstFailed]
}

/// Pure: run totals over the stage rows; unknown = tests with no verdict (incomplete).
func runTotals(_ stages: [[String: Any]]) -> [String: Int] {
    var totals = ["passed": 0, "failed": 0, "skipped": 0, "known_issues": 0, "unknown": 0]
    for stage in stages {
        for key in ["passed", "failed", "skipped", "known_issues"] { totals[key, default: 0] += stage[key] as? Int ?? 0 }
        totals["unknown", default: 0] += (stage["incomplete_tests"] as? [Any] ?? []).count + (stage["incomplete_tests_truncated"] as? Int ?? 0)
    }
    return totals
}

/// Pure: the history row for a finished result: totals, names, changes since
/// `previous`, and no paths into the run dir (it is about to be deleted).
func summaryRow(result: [String: Any], previous: [String: Any]?) -> [String: Any] {
    var row = result
    row["roots"] = nil
    let stages = (result["stages"] as? [[String: Any]] ?? []).map { stage -> [String: Any] in
        var compact = stage
        compact["artifacts"] = nil
        compact["blocked_suites"] = (stage["blocked_details"] as? [Any] ?? []).count
        compact["blocked_details"] = nil
        return compact
    }
    row["stages"] = stages
    row["totals"] = runTotals(stages)
    return row.merging(failureChanges(current: row, previous: previous)) { $1 }
}

// MARK: Run tidy and retention (Rick 2026-11-08)
// Each run kept DerivedData (~5 GB), PackageBuild (~1.3 GB) and swift-cache
// forever; the M4 testbed reached 102 GB and 86% full. The run removes its own
// regenerable build scratch once result.json and the history row exist (like
// `make clean`), and finished runs older than 14 days are removed at the start
// of the next run. history.jsonl, pending-metrics* and unfinished runs are never touched.
// Memory: O(entries in one directory) for retention; the size walk streams
// (FileManager's enumerator holds one directory level at a time).
let buildScratchNames = ["DerivedData", "PackageBuild", "swift-cache"]
let retentionDays = 3

/// "2026-11-08T20-19-00Z-1A2B3C4D" (prepareRoots' runID) -> its UTC start; nil = not a run dir.
/// The WHOLE name must have that shape (Codex sweep 11/09 F1: a timestamp
/// prefix alone let "…Z-family-backup" pass).
func runDate(fromName name: String) -> Date? {
    guard name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z-[0-9A-Z]{8}$"#, options: .regularExpression) != nil
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
    return formatter.date(from: String(name.prefix(20)))
}

/// Pure retention decision: run dirs whose NAME date is more than `days` old (mtime ignored),
/// finished or not: a run lasts hours (watchdog 4 h), so a 3-day-old one without result.json crashed.
func retentionCandidates(_ entries: [(name: String, finished: Bool)], now: Date, days: Int = retentionDays) -> [String] {
    entries.filter { entry in
        guard let started = runDate(fromName: entry.name) else { return false }
        return now.timeIntervalSince(started) > Double(days) * 86_400
    }.map(\.name).sorted()
}

/// Pure tidy decision: which of the run's own build dirs may go now (none before result.json, none with --keep-run).
func buildScratchToRemove(run: URL, resultExists: Bool, keepBuild: Bool, publishReaped: Bool) -> [URL] {
    guard resultExists, !keepBuild, publishReaped else { return [] }
    return buildScratchNames.map { run.appendingPathComponent($0) }
}

/// Pure tidy decision for the whole run: nil = remove it, else why it stays. It goes only when its
/// summary row is in history.jsonl and the metrics row was published; a queued publish keeps
/// result.json for a manual retry (the 3-day retention removes it later).
func keepRunReason(publish: String, resultExists: Bool, summaryInHistory: Bool, keepRun: Bool, publishReaped: Bool) -> String? {
    if keepRun { return "--keep-run" }
    if !publishReaped { return "publisher not reaped" }
    if !resultExists { return "no result.json" }
    if publish != "published" { return "publish \(publish); result.json kept for the retry, removed by retention after \(retentionDays) days" }
    if !summaryInHistory { return "no summary row in history.jsonl" }
    return nil
}

func isSymlink(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }

func allocatedBytes(_ url: URL) -> Int64 {
    guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else { return 0 }
    var total: Int64 = 0
    for case let item as URL in walk { total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
    return total
}

/// The end-of-run tidy: the whole run once its summary is safe (keepRunReason), else just its
/// build scratch. Returns the lines to print.
func tidyRun(run: URL, publish: String, keepRun: Bool, publishReaped: Bool) -> [String] {
    let root = run.deletingLastPathComponent()
    let inHistory = historyHasRun(root.appendingPathComponent("history.jsonl"), runID: run.lastPathComponent)
    let resultExists = fm.fileExists(atPath: run.appendingPathComponent("result.json").path)
    guard let why = keepRunReason(publish: publish, resultExists: resultExists, summaryInHistory: inHistory, keepRun: keepRun, publishReaped: publishReaped) else {
        do {
            guard !isSymlink(run) else { throw RunError("run dir is a symlink") }
            _ = try guarded(run, under: root)
            let size = allocatedBytes(run)          // the enumerator does not descend symlinks
            try fm.removeItem(at: run)                 // removes a symlink inside, never its target
            return ["GAUNTLET TIDY removed run \(run.path) (\(String(format: "%.2f", Double(size) / 1e9)) GB); summary in history.jsonl"]
        } catch { return ["GAUNTLET TIDY warning: could not remove \(run.path): \(error)"] }
    }
    return [tidyBuildScratch(run: run, keepBuild: keepRun, publishReaped: publishReaped), "GAUNTLET TIDY kept run (\(why)) \(run.path)"]
}

/// Removes the run's build scratch when buildScratchToRemove allows it; returns the one line to print.
func tidyBuildScratch(run: URL, keepBuild: Bool, publishReaped: Bool) -> String {
    let resultExists = fm.fileExists(atPath: run.appendingPathComponent("result.json").path)
    let targets = buildScratchToRemove(run: run, resultExists: resultExists, keepBuild: keepBuild, publishReaped: publishReaped)
    guard !targets.isEmpty else {
        let why = keepBuild ? "--keep-run" : !resultExists ? "no result.json" : "publisher not reaped"
        return "GAUNTLET TIDY kept build products (\(why)) in \(run.path)"
    }
    var bytes: Int64 = 0
    var problems: [String] = []
    for target in targets where fm.fileExists(atPath: target.path) {
        // A symlink here is not the runner's own output: never follow or remove it.
        guard !isSymlink(target), (try? guarded(target, under: run)) != nil else { problems.append("skipped \(target.lastPathComponent)"); continue }
        let size = allocatedBytes(target)
        do { try fm.removeItem(at: target); bytes += size } catch { problems.append("\(target.lastPathComponent): \(error.localizedDescription)") }
    }
    let gb = String(format: "%.2f", Double(bytes) / 1e9)
    return "GAUNTLET TIDY removed build products (\(gb) GB) from \(run.path)" + (problems.isEmpty ? "" : " warning=\"\(problems.joined(separator: "; "))\"")
}

/// The marker prepareRoots writes into every run dir it makes: the run's own id.
let runMarkerName = ".gauntlet-run"

func isRegularFile(_ url: URL) -> Bool {
    var st = stat()
    return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
}

/// Proof the runner made `dir` (Codex sweep 11/09 F1): its marker names it, or —
/// runs made before the marker — the runner's own `.write-probe` files sit in
/// its home, tmp and catalog roots. A directory without that proof is never removed.
func runnerOwns(_ dir: URL) -> Bool {
    let marker = dir.appendingPathComponent(runMarkerName)
    if isRegularFile(marker) {
        let text = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == dir.lastPathComponent
    }
    return ["home", "tmp", "catalog"].allSatisfy { isRegularFile(dir.appendingPathComponent($0).appendingPathComponent(".write-probe")) }
}

/// The results root's real run dirs (no symlinks, no files, made by the runner) and whether each has result.json.
func runEntries(_ resultsRoot: URL) -> [(name: String, finished: Bool)] {
    ((try? fm.contentsOfDirectory(atPath: resultsRoot.path)) ?? []).sorted().compactMap { name in
        let dir = resultsRoot.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard !isSymlink(dir), fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue, runnerOwns(dir) else { return nil }
        return (name, fm.fileExists(atPath: dir.appendingPathComponent("result.json").path))
    }
}

/// Removes runs older than retentionDays (by name); returns one line per run removed. The safety
/// net for runs the end-of-run tidy kept (queued publish, crash, --keep-run).
/// Rick 2026-11-08: "delete them all, once we have the summary data" -- history.jsonl keeps every
/// run's summary row, so these run dirs are removed outright rather than moved to .trash (his
/// explicit exception, for gauntlet run dirs only; DECISIONS). history.jsonl and pending-metrics* are never touched.
/// Codex sweep 11/09 F2: "once we have the summary data" — a run whose summary
/// row is NOT in history.jsonl (a crash before the row) keeps its logs and
/// result.json, the only record of it; only its regenerable build products go.
func retainFinishedRuns(resultsRoot: URL, now: Date) -> [String] {
    let history = resultsRoot.appendingPathComponent("history.jsonl")
    return retentionCandidates(runEntries(resultsRoot), now: now).map { name in
        let dir = resultsRoot.appendingPathComponent(name)
        guard historyHasRun(history, runID: name) else {
            return "GAUNTLET RETENTION kept \(dir.path) (no summary row in history.jsonl — its logs are the only record); "
                + removeBuildScratch(run: dir)
        }
        do {
            _ = try guarded(dir, under: resultsRoot)
            try fm.removeItem(at: dir)
            return "GAUNTLET RETENTION removed \(dir.path) (run older than \(retentionDays) days; summary in history.jsonl)"
        } catch { return "GAUNTLET RETENTION warning: could not remove \(dir.path): \(error)" }
    }
}

/// Removes the run's own build products (never a symlink, never outside the run); the words to print.
func removeBuildScratch(run: URL) -> String {
    var bytes: Int64 = 0
    var problems: [String] = []
    for target in buildScratchNames.map({ run.appendingPathComponent($0) }) where fm.fileExists(atPath: target.path) {
        guard !isSymlink(target), (try? guarded(target, under: run)) != nil else { problems.append("skipped \(target.lastPathComponent)"); continue }
        let size = allocatedBytes(target)
        do { try fm.removeItem(at: target); bytes += size } catch { problems.append("\(target.lastPathComponent): \(error.localizedDescription)") }
    }
    return "removed build products (\(String(format: "%.2f", Double(bytes) / 1e9)) GB)" + (problems.isEmpty ? "" : " warning=\"\(problems.joined(separator: "; "))\"")
}

// A value-type run context; mutating methods are like non-const C++ members.
struct GauntletRunner {
    let repo: URL
    var arguments: [String]
    var away = false
    var dry = false
    var queueOnly = false
    /// Keep the whole run dir, build products included (debugging).
    var keepRun = false
    /// False while the publisher (which uses <run>/swift-cache) may still be running.
    var publishReaped = true
    var machine = "m4"
    var only = Set(stageOrder)
    var manifestPath: URL
    var resultsRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan/gauntlet")
    var stages: [[String: Any]] = []
    var stageMap: [String: [String: Any]] = [:]
    var validationErrors: [String] = []
    var stamp = ""
    var runID = ""
    var run = URL(fileURLWithPath: "/")
    var totalStart = 0.0
    var environment: [String: String] = [:]
    var roots: [String: String] = [:]
    var result: [String: Any] = [:]
    var outputs: [[String: Any]] = []
    var buildOK = false
    var contaminated = false
    var fatalReason: String?
    var xctestrun: URL?
    /// The package adapter's one build (nil = not needed / not attempted).
    var packageBuildOK: Bool?
    var packageBuildReason: String?
    var packagePath: URL { repo.appendingPathComponent("VideoScan/VideoScanCore") }
    var packageScratch: String { run.appendingPathComponent("PackageBuild").path }

    init(repo: URL, arguments: [String]) {
        self.repo = repo
        self.arguments = arguments
        manifestPath = repo.appendingPathComponent("scripts/gauntlet/manifest.json")
    }

    mutating func parseOptions() throws -> Bool {
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            switch flag {
            case "--away": away = true
            case "--dry-run": dry = true
            case "--queue-only": queueOnly = true
            case "--keep-run", "--keep-build": keepRun = true          // --keep-build: the old name
            case "--machine", "--only", "--manifest", "--results-root":
                guard !arguments.isEmpty else { throw RunError("missing value for \(flag)") }
                let value = arguments.removeFirst()
                if flag == "--machine" { machine = value }
                if flag == "--only" { only = Set(value.split(separator: ",").map(String.init)) }
                if flag == "--manifest" { manifestPath = URL(fileURLWithPath: value).standardizedFileURL }
                if flag == "--results-root" { resultsRoot = URL(fileURLWithPath: value).standardizedFileURL }
            case "--help", "-h":
                print("run_gauntlet.sh --away [--machine m4|m5|m1] [--dry-run] [--only stage,...] [--manifest PATH] [--results-root PATH] [--queue-only] [--keep-run]")
                return false
            default: throw RunError("unknown argument: \(flag)")
            }
        }
        return true
    }

    mutating func validateInventory() throws {
        guard away || dry else { throw RunError("--away required; test hosts must run only in an authorized away window") }
        guard ["m4", "m5", "m1"].contains(machine), !only.isEmpty, only.isSubset(of: Set(stageOrder)) else { throw RunError("invalid machine or stage selection") }
        let manifest = try readObject(manifestPath)
        guard let declaredStages = manifest["stages"] as? [[String: Any]], Set(declaredStages.compactMap { $0["name"] as? String }) == Set(stageOrder), declaredStages.count == stageOrder.count else { throw RunError("manifest must declare each stage exactly once") }
        stages = declaredStages
        stageMap = Dictionary(uniqueKeysWithValues: stages.map { ($0["name"] as! String, $0) })
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal)
        let validationLog = URL(fileURLWithPath: "/private/tmp/gauntlet-inventory-\(UUID().uuidString).json")
        let validationCache = "/private/tmp/gauntlet-inventory-cache-\(UUID().uuidString)"
        let validationRun = try command(["/usr/bin/swift", "-module-cache-path", validationCache, repo.appendingPathComponent("scripts/gauntlet/inventory.swift").path, "--validate", repo.path, manifestPath.path], log: validationLog, timeout: 120)
        guard !validationRun.timedOut && !validationRun.contaminated else { throw RunError("inventory watchdog failure") }
        let validation = (try? String(contentsOf: validationLog, encoding: .utf8)) ?? ""
        guard let validationData = validation.data(using: .utf8), let validationObject = try? JSONSerialization.jsonObject(with: validationData) as? [String: Any], let errors = validationObject["errors"] as? [String] else { throw RunError("inventory validation unavailable: \(validation.prefix(500))") }
        validationErrors = errors
    }

    func printPlan() {
        print("GAUNTLET DRY RUN machine=\(machine) configuration=Release")
        print("Inventory: \(validationErrors.isEmpty ? "valid" : validationErrors.joined(separator: "; "))")
        print("Isolation: per-run home, App Support, catalog, preferences, caches, logs, archive, fixtures; canonical write allowlist")
        print("Build: ONE xcodebuild build-for-testing -scheme VideoScan -testPlan VideoScan-CI -configuration Release ENABLE_TESTABILITY=YES -derivedDataPath <run>/DerivedData")
        print("Package: ONE swift build --build-tests -c release -Xswiftc -enable-testing --package-path VideoScan/VideoScanCore --scratch-path <run>/PackageBuild, then swift test --skip-build per stage with package_selectors")
        for name in stageOrder {
            let entry = stageMap[name]!
            let selectors = entry["selectors"] as? [String] ?? []
            let blocked = entry["blocked"] as? [[String: Any]] ?? []
            let packageSelectors = entry["package_selectors"] as? [String] ?? []
            let package = packageSelectors.isEmpty ? "" : " package_selectors=\(packageSelectors.count) package_expected_floor=\(entry["package_expected_floor"] ?? 0)"
            print("\(name): \(name == "ui" ? "UI not run (phase 2)" : !only.contains(name) ? "not_run (not selected)" : "test-without-building selectors=\(selectors.count) expected_floor=\(entry["expected_floor"] ?? 0)\(package) blocked=\(blocked.count)")")
        }
        print("Results: history.jsonl summary row (totals, failed/skipped/incomplete test names, new_failures, fixed, first_failed); \(resultsRoot.path)/<run-id>/result.json while the run dir lives; metrics publication queued on failure")
        print("Tidy: after the summary row is in history.jsonl and publish=published, remove the whole run dir\(keepRun ? " (skipped: --keep-run)" : ""); queued: remove only <run>/{\(buildScratchNames.joined(separator: ","))}; retention: runs older than \(retentionDays) days (by run name) are removed")

    }

    mutating func prepareRoots() throws {
        // Only runner-owned storage is created; canonical checks precede every write.
        let allowedParents = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VideoScan"), URL(fileURLWithPath: "/private/tmp"), URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath()]
        guard let parent = allowedParents.first(where: { resultsRoot.path.hasPrefix($0.path + "/") }) else { throw RunError("results root must be under VideoScan logs or scratch") }
        _ = try guarded(resultsRoot, under: parent)
        try fm.createDirectory(at: resultsRoot, withIntermediateDirectories: true)
        stamp = ISO8601DateFormatter().string(from: Date())
        runID = stamp.replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        run = try guarded(resultsRoot.appendingPathComponent(runID), under: resultsRoot)
        try fm.createDirectory(at: run, withIntermediateDirectories: false)
        try write(Data(runID.utf8), to: run.appendingPathComponent(runMarkerName), root: run)   // ownership proof for retention
        totalStart = monotonic()
        environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("VS_") && !key.hasPrefix("VIDEOSCAN_") && !key.hasPrefix("TEST_RUNNER_") && !key.hasPrefix("XCTest")
        }
        for key in ["home", "app-support", "catalog", "preferences", "caches", "logs", "archive", "fixtures", "tmp", "DerivedData"] {
            let path = try guarded(run.appendingPathComponent(key), under: run)
            try fm.createDirectory(at: path, withIntermediateDirectories: false)
            let probe = path.appendingPathComponent(".write-probe"); try write(Data("ok".utf8), to: probe, root: run)
            roots[key] = path.path
        }
        environment["HOME"] = roots["home"]; environment["CFFIXED_USER_HOME"] = roots["home"]; environment["TMPDIR"] = roots["tmp"]! + "/"
        // SwiftPM's manifest compiler can derive its default cache from the account
        // database rather than HOME. Give both it and Clang explicit per-run caches.
        for key in ["CLANG_MODULE_CACHE_PATH", "SWIFT_MODULECACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "XDG_CACHE_HOME"] {
            environment[key] = roots["caches"]!
        }
        environment["VS_UI_TEST"] = "1"; environment["CI"] = "1"
        // App test-host gates suppress production stores; these explicit roots also
        // document the future adapters' contract, not an OS-wide confinement claim.
        for (key, value) in roots { environment["VS_GAUNTLET_" + key.uppercased().replacingOccurrences(of: "-", with: "_") + "_ROOT"] = value }
    }

    mutating func prepareAdapterEnvironment() throws {
        for entry in stages {
            for (key, value) in entry["environment"] as? [String: String] ?? [:] {
                guard ["VIDEOSCAN_PERF", "VIDEOSCAN_PERF_FILE_COUNT", "VIDEOSCAN_PERF_DURATION", "VIDEOSCAN_PERF_TIME_LIMIT_MIN", "VIDEOSCAN_PERF_RESULTS"].contains(key) else { throw RunError("unsupported adapter environment key: \(key)") }
                let expanded = value.replacingOccurrences(of: "{run_dir}", with: run.path)
                if key == "VIDEOSCAN_PERF_RESULTS" { _ = try guarded(URL(fileURLWithPath: expanded), under: run) }
                environment[key] = expanded
            }
        }
    }

    mutating func initializeResult() {
        result = ["schema": 1, "run_id": runID, "ts": stamp, "commit": capture(["git", "-C", repo.path, "rev-parse", "HEAD"]), "branch": capture(["git", "-C", repo.path, "branch", "--show-current"]), "dirty": !capture(["git", "-C", repo.path, "status", "--porcelain"]).isEmpty, "machine": machine, "configuration": "Release", "binary_sha256": NSNull(), "status": "failed", "build_s": 0.0, "roots": roots, "inventory_errors": validationErrors]
    }

    /// Builds see the real HOME: since Xcode 27.1 the Metal Toolchain is a
    /// per-user downloaded component, and a build under the confined HOME fails
    /// with "missing Metal Toolchain" (M5, 2026-10-21). Confinement exists to
    /// keep TESTS away from real stores, so the test commands keep `environment`.
    var buildEnvironment: [String: String] {
        var env = environment
        let real = ProcessInfo.processInfo.environment
        for key in ["HOME", "CFFIXED_USER_HOME"] { env[key] = real[key] ?? NSHomeDirectory() }
        return env
    }

    mutating func build() throws {
        if fatalReason == nil {
            let cmd = ["xcodebuild", "build-for-testing", "-project", repo.appendingPathComponent("VideoScan/VideoScan.xcodeproj").path, "-scheme", "VideoScan", "-testPlan", "VideoScan-CI", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", roots["DerivedData"]!, "-skip-testing:VideoScanUITests", "ENABLE_TESTABILITY=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS="]
            let build = try command(cmd, log: run.appendingPathComponent("build.log"), timeout: 3600, environment: buildEnvironment)
            result["build_s"] = build.elapsed; result["build_exit_code"] = build.code
            buildOK = build.code == 0; contaminated = build.contaminated
            if !buildOK { fatalReason = build.timedOut ? "build watchdog timeout" : "build exit \(build.code)" }
        }
        let productRoot = URL(fileURLWithPath: roots["DerivedData"]!).appendingPathComponent("Build/Products")
        if buildOK {
            xctestrun = try fm.contentsOfDirectory(at: productRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }.sorted { $0.path < $1.path }.first
            guard let testRun = xctestrun else { throw RunError("build produced no .xctestrun") }
            var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: testRun), format: nil)
            plist = patch(plist)
            try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: testRun, root: run)
            let binary = productRoot.appendingPathComponent("Release/VideoScan.app/Contents/MacOS/VideoScan")
            result["binary_sha256"] = capture(["/usr/bin/shasum", "-a", "256", binary.path]).split(separator: " ").first.map(String.init) as Any? ?? NSNull()
        }
    }

    /// The package adapter's ONE build (2026-10-18): the VideoScanCore
    /// package's tests in Release, in the run's own scratch path and isolated
    /// environment, only when a selected stage has package selectors. Like
    /// the app build it is never repeated between stages.
    mutating func buildPackage() throws {
        let wanted = stages.contains { entry in
            only.contains(entry["name"] as? String ?? "") && !((entry["package_selectors"] as? [String] ?? []).isEmpty)
        }
        guard wanted, fatalReason == nil, !contaminated else { return }
        let cmd = ["swift", "build", "--build-tests", "-c", "release", "-Xswiftc", "-enable-testing", "--package-path", packagePath.path, "--scratch-path", packageScratch]
        let build = try command(cmd, log: run.appendingPathComponent("package-build.log"), timeout: 3600, environment: buildEnvironment)
        result["package_build_s"] = build.elapsed; result["package_build_exit_code"] = build.code
        if build.contaminated { contaminated = true }
        packageBuildOK = build.code == 0 && !build.contaminated
        if packageBuildOK != true {
            packageBuildReason = build.timedOut ? "package build watchdog timeout"
                : "package build exit \(build.code)" + (build.contaminated ? " (unreaped process contamination)" : "")
            // RED, never AMBER (Codex 11/05): contamination blocks every stage
            // before runPackageSuites could fail one, so the run itself fails here.
            fatalReason = fatalReason ?? packageBuildReason
        }
    }

    /// One stage's package suites: `swift test --skip-build` on the build
    /// above, one `--filter` per suite (`VideoScanCoreTests.<Suite>/`, the
    /// slash so a suite never matches a longer name), counted from the log.
    mutating func runPackageSuites(_ name: String, selectors: [String], floor: Int, timeout: Double) -> (row: [String: Any], names: TestNames) {
        var output: [String: Any] = ["selectors": selectors.count, "expected": floor, "status": "failed", "reason": NSNull(), "exit_code": NSNull()]
        var names = TestNames()
        guard packageBuildOK == true else {
            // A package build that failed is RED (Rick 2026-11-05), never "blocked".
            output["status"] = "failed"; output["reason"] = packageBuildReason ?? "package build did not run"
            return (output, names)
        }
        let patterns = selectors.map { NSRegularExpression.escapedPattern(for: $0) + "/" }
        let filters = patterns.flatMap { ["--filter", $0] }
        let log = run.appendingPathComponent("\(name)-package.log")
        let events = run.appendingPathComponent("\(name)-package-events.jsonl")
        let cmd = ["swift", "test", "--skip-build", "-c", "release", "--package-path", packagePath.path, "--scratch-path", packageScratch,
                   "--event-stream-output-path", events.path] + filters
        // The independent XCTest count: the package listed, not run, then narrowed
        // by `patterns` here — `swift test list` ignores --filter (kept on the
        // command in case a later SwiftPM honours it; filtering twice is a no-op).
        let listLog = run.appendingPathComponent("\(name)-package-list.log")
        let listCmd = ["swift", "test", "list", "--skip-build", "-c", "release", "--package-path", packagePath.path, "--scratch-path", packageScratch] + filters
        do {
            let listing = try command(listCmd, log: listLog, timeout: 600, environment: environment)
            if listing.contaminated {
                // Isolation already failed: launch nothing more (Codex 2026-11-05 re-review 2, P2).
                contaminated = true
                output["status"] = "failed"; output["reason"] = "unreaped process contamination (swift test list)"
                return (output, names)
            }
            let listed: String? = listing.code == 0 ? (try? String(contentsOf: listLog, encoding: .utf8)) : nil
            let execution = try command(cmd, log: log, timeout: timeout, environment: environment)
            if execution.contaminated { contaminated = true }
            output["exit_code"] = execution.code
            output["elapsed_s"] = execution.elapsed
            let stream = (try? String(contentsOf: events, encoding: .utf8)) ?? ""
            let console = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let counts = countsFromPackageRun(eventStream: stream, console: console, xctestList: listed, filters: patterns)
            names = packageNames(eventStream: stream, console: console, xctestList: listed, filters: patterns)
            let verdict = classify(exitCode: execution.code, counts: counts, floor: floor)
            output["status"] = verdict.0
            output["reason"] = verdict.1 as Any? ?? NSNull()
            if let counts { for (key, value) in counts { output[key] = value } }
            if execution.timedOut { output["status"] = "failed"; output["reason"] = "package watchdog timeout" }
            if execution.contaminated { output["status"] = "failed"; output["reason"] = "unreaped process contamination" }
        } catch { output["reason"] = String(describing: error) }
        return (output, names)
    }

    func patch(_ object: Any) -> Any {
        if let list = object as? [Any] { return list.map(patch) }
        guard var dict = object as? [String: Any] else { return object }
        for (key, value) in dict { dict[key] = patch(value) }
        if dict["TestBundlePath"] != nil {
            var env = dict["EnvironmentVariables"] as? [String: String] ?? [:]
            for (key, value) in environment where key.hasPrefix("VS_") || key.hasPrefix("VIDEOSCAN_") || ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "CI"].contains(key) { env[key] = value }
            dict["EnvironmentVariables"] = env
        }
        return dict
    }

    func unavailableStage(_ name: String, entry: [String: Any], floor: Int) -> [String: Any]? {
        if name == "ui" { return stageResult(name, "not_run", "phase 2", floor: floor) }
        if !only.contains(name) { return stageResult(name, "not_run", "not selected", floor: floor) }
        if contaminated || interrupted != 0 || !buildOK { return stageResult(name, "blocked", contaminated ? "unreaped process contamination" : interrupted != 0 ? "interrupted" : fatalReason, floor: floor) }
        let selectors = entry["selectors"] as? [String] ?? []
        let blocked = entry["blocked"] as? [[String: Any]] ?? []
        let missingTools = (entry["requires_tools"] as? [String] ?? []).filter { !fm.isExecutableFile(atPath: $0) }
        // A missing tool is a broken host, not an unadapted suite: RED, not AMBER.
        if !missingTools.isEmpty { return stageResult(name, "failed", "required fixture tools unavailable: \(missingTools.joined(separator: ", "))", floor: floor) }
        let packageSelectors = entry["package_selectors"] as? [String] ?? []
        if selectors.isEmpty && packageSelectors.isEmpty { return stageResult(name, "blocked", blocked.isEmpty ? "no safe phase 1 adapter" : "unsafe or unadapted suites: \(blocked.count)", floor: floor) }
        return nil
    }

    /// Fold the package sub-run into the stage: counts add up, a package
    /// failure (or a package-only stage's verdict) decides the status, and
    /// both reasons are kept.
    func mergePackage(_ package: [String: Any], into output: inout [String: Any], xcodeRan: Bool) {
        output["package"] = package
        for key in ["passed", "failed", "skipped", "known_issues"] {
            if let value = package[key] as? Int { output[key] = (output[key] as? Int ?? 0) + value }
        }
        let packageStatus = package["status"] as? String ?? "failed"
        let packageReason = (package["reason"] as? String).map { "package: \($0)" }
        if !xcodeRan {
            output["status"] = packageStatus
            output["reason"] = packageReason as Any? ?? NSNull()
            output["exit_code"] = package["exit_code"] ?? NSNull()
        } else if packageStatus != "passed" {
            let xcodeReason = output["reason"] as? String
            output["status"] = (output["status"] as? String == "failed" || packageStatus == "failed") ? "failed" : packageStatus
            output["reason"] = [xcodeReason, packageReason].compactMap { $0 }.joined(separator: "; ")
        }
    }

    mutating func executeStage(_ name: String) -> [String: Any] {
        let entry = stageMap[name]!
        let floor = entry["expected_floor"] as? Int ?? 1
        if let unavailable = unavailableStage(name, entry: entry, floor: floor) { return unavailable }
        let selectors = entry["selectors"] as? [String] ?? []
        let packageSelectors = entry["package_selectors"] as? [String] ?? []
        let blocked = entry["blocked"] as? [[String: Any]] ?? []
        let timeout = Double(entry["timeout_s"] as? Int ?? 1800)
        let bundle = run.appendingPathComponent("\(name).xcresult")
        var output = stageResult(name, "failed", nil, floor: floor)
        output["blocked_details"] = blocked
        if let modes = entry["modes"] { output["modes"] = modes }
        let start = monotonic()
        var artifacts: [String] = []
        var names = TestNames()
        if !selectors.isEmpty {
            let cmd = ["xcodebuild", "test-without-building", "-xctestrun", xctestrun!.path, "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO", "-resultBundlePath", bundle.path, "-skip-testing:VideoScanUITests"] + selectors.map { "-only-testing:\($0)" }
            do {
                let execution = try command(cmd, log: run.appendingPathComponent("\(name).log"), timeout: timeout, environment: environment)
                contaminated = execution.contaminated
                output["exit_code"] = execution.code
                let summary = run.appendingPathComponent("\(name)-summary.json")
                let extraction = try command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle.path], log: summary, timeout: 60)
                applyVerdict(execution, extraction: extraction, summary: summary, floor: floor, output: &output)
                names.merge(try stageXcodeNames(name, summary: summary, bundle: bundle))
            } catch { output["reason"] = String(describing: error) }
            artifacts += [bundle.lastPathComponent, "\(name).log", "\(name)-summary.json"]
        }
        if !packageSelectors.isEmpty && !contaminated {
            let package = runPackageSuites(name, selectors: packageSelectors,
                                           floor: entry["package_expected_floor"] as? Int ?? 1, timeout: timeout)
            mergePackage(package.row, into: &output, xcodeRan: !selectors.isEmpty)
            names.merge(package.names)
            artifacts += ["package-build.log", "\(name)-package.log", "\(name)-package-events.jsonl"]
        }
        // Safe subset passed, but the stage still holds unadapted suites
        // (AMBER-class); an AMBER stage keeps its status and says both.
        if output["status"] as? String == "passed" && !blocked.isEmpty {
            output["status"] = "blocked"; output["reason"] = "safe subset passed; unsafe or unadapted suites: \(blocked.count)"
        } else if output["status"] as? String == "amber" && !blocked.isEmpty {
            output["reason"] = "\(output["reason"] as? String ?? "amber"); unsafe or unadapted suites: \(blocked.count)"
        }
        output["incomplete"] = output["status"] as? String == "passed" ? 0 : 1
        output["elapsed_s"] = monotonic() - start
        output["artifacts"] = artifacts
        return output.merging(names.fields) { $1 }
    }

    /// The xcode half's names: failures from <stage>-summary.json; skipped names
    /// from the bundle's tests tree, fetched only when the summary counted skips.
    func stageXcodeNames(_ name: String, summary: URL, bundle: URL) throws -> TestNames {
        let object = try? readObject(summary)
        var tests: Any?
        if (object?["skippedTests"] as? Int ?? 0) > 0 {
            let treeLog = run.appendingPathComponent("\(name)-tests.json")
            let tree = try command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle.path], log: treeLog, timeout: 120)
            if tree.code == 0 { tests = try? JSONSerialization.jsonObject(with: Data(contentsOf: treeLog)) }
        }
        return xcodeNames(summary: object, tests: tests)
    }

    mutating func applyVerdict(_ execution: CommandResult, extraction: CommandResult, summary: URL, floor: Int, output: inout [String: Any]) {
        let counts = extraction.code == 0 ? (try? readObject(summary)).flatMap(countsFromSummary) : nil
        let verdict = classify(exitCode: execution.code, counts: counts, floor: floor)
        output["status"] = verdict.0
        output["reason"] = verdict.1 as Any? ?? NSNull()
        if let counts { for (key, value) in counts { output[key] = value } }
        if execution.timedOut { output["reason"] = "stage watchdog timeout" }
        if execution.contaminated || extraction.contaminated { contaminated = true; output["status"] = "failed"; output["reason"] = "unreaped process contamination" }
    }

    mutating func aggregateResults() {
        for name in stageOrder where !outputs.contains(where: { $0["name"] as? String == name }) { outputs.append(stageResult(name, name == "ui" ? "not_run" : "blocked", name == "ui" ? "phase 2" : fatalReason ?? "interrupted")) }
        outputs.sort { stageOrder.firstIndex(of: $0["name"] as! String)! < stageOrder.firstIndex(of: $1["name"] as! String)! }
        for index in outputs.indices {
            let entry = stageMap[outputs[index]["name"] as! String]!
            outputs[index]["blocked_details"] = entry["blocked"] ?? []
            if let modes = entry["modes"] { outputs[index]["modes"] = modes }
        }
        result["stages"] = outputs; result["elapsed_s"] = monotonic() - totalStart
        result["totals"] = runTotals(outputs)
        // Defence in depth (Codex 11/05): a build that did not exit 0, or any
        // contamination, is RED whatever the stage rows say.
        let buildFailed = (result["build_exit_code"] as? Int32).map { $0 != 0 } ?? false
            || (result["package_build_exit_code"] as? Int32).map { $0 != 0 } ?? false || packageBuildOK == false
        let failed = fatalReason != nil || buildFailed || contaminated || outputs.contains { $0["status"] as? String == "failed" }
        // GREEN = every stage passed; RED = a failure (test, floor, inventory,
        // build, watchdog); AMBER = only tracked known issues, unadapted
        // ("blocked") suites and stages not run (Rick 2026-11-05).
        result["status"] = failed ? "failed" : outputs.allSatisfy { $0["status"] as? String == "passed" } ? "passed" : "amber"
        result["amber_reasons"] = failed ? [] : amberReasons(outputs)
        if let fatalReason { result["reason"] = fatalReason }
        result["publish"] = "queued"
        if interrupted != 0 { result["interrupted_signal"] = interrupted; interrupted = 0 }
    }

    /// Why a run is AMBER, with counts: "7 known issues (regression 7)",
    /// "6 stages blocked (912 suites)", "ui not run (phase 2)".
    func amberReasons(_ stages: [[String: Any]]) -> [String] {
        var reasons: [String] = []
        let known = stages.compactMap { stage -> (String, Int)? in
            let n = stage["known_issues"] as? Int ?? 0
            return n > 0 ? (stage["name"] as? String ?? "?", n) : nil
        }
        let total = known.reduce(0) { $0 + $1.1 }
        if total > 0 { reasons.append("\(total) known issue\(total == 1 ? "" : "s") (\(known.map { "\($0.0) \($0.1)" }.joined(separator: ", ")))") }
        let held = stages.filter { ["blocked", "amber"].contains($0["status"] as? String ?? "") && !($0["blocked_details"] as? [Any] ?? []).isEmpty }
        let suites = held.reduce(0) { $0 + ($1["blocked_details"] as? [Any] ?? []).count }
        if !held.isEmpty { reasons.append("\(held.count) stage\(held.count == 1 ? "" : "s") blocked (\(suites) unadapted suites)") }
        let empty = stages.filter { $0["status"] as? String == "blocked" && ($0["blocked_details"] as? [Any] ?? []).isEmpty }
        if !empty.isEmpty { reasons.append("\(empty.count) stage\(empty.count == 1 ? "" : "s") without an adapter (\(empty.compactMap { $0["name"] as? String }.joined(separator: ", ")))") }
        for stage in stages where stage["status"] as? String == "not_run" {
            reasons.append("\(stage["name"] as? String ?? "?") not run (\(stage["reason"] as? String ?? "?"))")
        }
        return reasons
    }

    mutating func publishResults() throws -> Int32 {
        let resultPath = run.appendingPathComponent("result.json")
        try write(json(result), to: resultPath, root: run)
        let publishCommand = ["/usr/bin/swift", "-module-cache-path", run.appendingPathComponent("swift-cache").path, repo.appendingPathComponent("scripts/gauntlet/publish.swift").path, resultPath.path] + (queueOnly ? ["--queue-only"] : [])
        let published = try? command(publishCommand, log: run.appendingPathComponent("publish.log"), timeout: 180)
        publishReaped = !(published?.contaminated ?? false)
        result["publish"] = published?.code == 0 ? "published" : published?.code == 1 ? "queued" : "queue_failed"
        if result["publish"] as? String == "queue_failed" { result["status"] = "failed"; result["publish_reason"] = "publisher could not confirm durable queue; retry result.json manually" }
        let history = resultsRoot.appendingPathComponent("history.jsonl")
        let summary = summaryRow(result: result, previous: previousRow(history: history, machine: machine))
        for key in ["totals", "compared_to", "new_failures", "fixed", "first_failed"] { result[key] = summary[key] }
        try write(json(result), to: resultPath, root: run)
        var row = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]); row.append(0x0a)
        try append(row, to: history, root: resultsRoot, sync: true)    // durable before the run dir may go
        let totals = result["totals"] as? [String: Int] ?? [:]
        print("GAUNTLET SUMMARY passed=\(totals["passed"] ?? 0) failed=\(totals["failed"] ?? 0) skipped=\(totals["skipped"] ?? 0) unknown=\(totals["unknown"] ?? 0) new_failures=\((summary["new_failures"] as? [String] ?? []).joined(separator: ",")) fixed=\((summary["fixed"] as? [String] ?? []).count) history=\(history.path)")
        let labels = outputs.map { "\($0["name"]!)=\(($0["status"] as! String).uppercased())" }.joined(separator: " ")
        let amber = (result["amber_reasons"] as? [String] ?? []).joined(separator: "; ")
        let status = result["status"] as! String
        print("GAUNTLET \(status.uppercased()) sha=\(String((result["commit"] as! String).prefix(8))) total=\(Int(monotonic() - totalStart))s \(labels) UI not run (phase 2)\(status == "amber" ? " amber=\"\(amber)\"" : "") results=\(resultPath.path) publish=\(result["publish"]!)")
        // AMBER is not a failure for a caller (exit 0); the line says AMBER.
        return ["passed", "amber"].contains(status) ? 0 : 1
    }

    mutating func execute() throws -> Int32 {
        guard try parseOptions() else { return 0 }
        try validateInventory()
        if dry { printPlan(); return validationErrors.isEmpty ? 0 : 1 }
        try prepareRoots()
        retainFinishedRuns(resultsRoot: resultsRoot, now: Date()).forEach { print($0) }
        try prepareAdapterEnvironment()
        initializeResult()
        signal(SIGINT, onSignal); signal(SIGTERM, onSignal); signal(SIGHUP, onSignal)
        fatalReason = validationErrors.isEmpty ? nil : "manifest inventory mismatch"
        do {
            try build()
            try buildPackage()
            for name in stageOrder { outputs.append(executeStage(name)) }
        } catch { fatalReason = String(describing: error) }
        aggregateResults()
        // Tidy only after result.json and the history row exist and the publisher is done with swift-cache.
        let exitCode = try publishResults()
        tidyRun(run: run, publish: result["publish"] as? String ?? "queued", keepRun: keepRun, publishReaped: publishReaped).forEach { print($0) }
        return exitCode
    }
}

func main() throws -> Int32 {
    // Test seam: count one package run's outputs, print the counts (or null).
    let arguments = Array(CommandLine.arguments.dropFirst())
    // Test seam: --count-package-output <stream> <console> <list> [filter-regex…]
    if arguments.first == "--count-package-output", arguments.count >= 4 {
        let read = { (path: String) in (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        let counts = countsFromPackageRun(eventStream: read(arguments[1]), console: read(arguments[2]), xctestList: read(arguments[3]),
                                          filters: Array(arguments.dropFirst(4)))
        print(counts.map { String(data: try! json($0), encoding: .utf8)! } ?? "null")
        return counts == nil ? 1 : 0
    }
    // Test seams for run tidy / retention (tests/test_gauntlet_run_tidy.py).
    let isoNow = { (text: String) in ISO8601DateFormatter().date(from: text) ?? Date() }
    if arguments.first == "--retention-plan", arguments.count == 3 {
        let entries = runEntries(URL(fileURLWithPath: arguments[1]))
        print(String(bytes: try json(retentionCandidates(entries, now: isoNow(arguments[2]))), encoding: .utf8) ?? "null")
        return 0
    }
    if arguments.first == "--retain", arguments.count == 3 {
        retainFinishedRuns(resultsRoot: URL(fileURLWithPath: arguments[1]), now: isoNow(arguments[2])).forEach { print($0) }
        return 0
    }
    // Test seam (Codex sweep 11/09 F3): append <n> lines "<tag> <i>" to <file> through `append`, as the history writer does.
    if arguments.first == "--append-lines", arguments.count == 4, let n = Int(arguments[3]) {
        let file = URL(fileURLWithPath: arguments[1])
        for i in 0..<n { try append(Data("{\"tag\": \"\(arguments[2])\", \"i\": \(i)}\n".utf8), to: file, root: file.deletingLastPathComponent(), sync: false) }
        return 0
    }
    // Test seam (closing pass G1): one append whose fsync fails (EIO) — the row must not stay.
    if arguments.first == "--append-fail-sync", arguments.count == 3 {
        let file = URL(fileURLWithPath: arguments[1])
        do {
            try append(Data("{\"tag\": \"\(arguments[2])\"}\n".utf8), to: file, root: file.deletingLastPathComponent(), sync: true,
                       syncer: { _ in errno = EIO; return -1 })
            print("APPENDED")
        } catch { print("THREW \(error)") }
        return 0
    }
    if arguments.first == "--tidy-run", arguments.count >= 3 {
        tidyRun(run: URL(fileURLWithPath: arguments[1]), publish: arguments[2], keepRun: arguments.dropFirst(3).contains("--keep-run"), publishReaped: true).forEach { print($0) }
        return 0
    }
    // Test seams for the summary row: names per source, and the row publishResults appends.
    let printJSON = { (value: Any) in print(String(bytes: try json(value), encoding: .utf8) ?? "null") }
    if arguments.first == "--package-names", arguments.count >= 4 {
        let read = { (path: String) in (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        try printJSON(packageNames(eventStream: read(arguments[1]), console: read(arguments[2]), xctestList: read(arguments[3]), filters: Array(arguments.dropFirst(4))).fields)
        return 0
    }
    if arguments.first == "--xcode-names", arguments.count >= 2 {
        let tests = arguments.count > 2 ? try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) : nil
        try printJSON(xcodeNames(summary: try readObject(URL(fileURLWithPath: arguments[1])), tests: tests).fields)
        return 0
    }
    if arguments.first == "--history-row", arguments.count == 3 {
        let result = try readObject(URL(fileURLWithPath: arguments[1]))
        try printJSON(summaryRow(result: result, previous: previousRow(history: URL(fileURLWithPath: arguments[2]), machine: result["machine"] as? String ?? "")))
        return 0
    }
    let script = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repo = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var runner = GauntletRunner(repo: repo, arguments: Array(CommandLine.arguments.dropFirst()))
    return try runner.execute()
}

do { exit(try main()) } catch { fputs("GAUNTLET FAILED preflight: \(error)\n", stderr); exit(1) }
