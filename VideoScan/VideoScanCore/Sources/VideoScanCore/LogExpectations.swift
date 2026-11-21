// LogExpectations.swift (VideoScanCore)
// gmock-style expectations on a test's captured log (Rick, 2026-11-21: "The
// mock log injected should be able to return to the unit test the output it
// expects in the log … expect conditions and a good mock whose output you
// control").
//
// `LogCapture` (TaskTreeScope.swift) is the mock: it records the lines of one
// test's task tree. This file is the EXPECT_CALL half: a test says which
// lines it expects, how often and in what order, and one verification names
// every expectation that was not met, with the captured lines that show why.
//
//     try await expectingLog(
//         .once(.hasPrefix("transcode: ")),                 // START
//         .once(.matching(/^transcode FAILED: .* exit code 228/)),
//         .never(.contains("Transcoded")),
//         .inOrder(.hasPrefix("transcode: "), .hasPrefix("transcode FAILED: ")),
//         .noOtherLines(matching: .contains("FAILED"))
//     ) {
//         try await job.run()                                // code under test
//     }
//
// The C++ / gmock mapping:
//
//     EXPECT_CALL(log, Write(HasSubstr("x"))).Times(1)    .once(.contains("x"))
//     .Times(n) / .Times(AtLeast(n)) / .Times(0)          .exactly(n, …) / .atLeast(n, …) / .never(…)
//     HasSubstr / StartsWith / MatchesRegex / Truly(pred)  .contains / .hasPrefix / .matching(/…/) / .line("…") { pred }
//     AllOf(m1, m2)                                        .all(m1, m2)
//     InSequence s;                                        .inOrder(…)
//     StrictMock<MockLog>                                  .noOtherLines()            (any line no expectation names)
//     … restricted to "uninteresting calls that matter"    .noOtherLines(matching: .contains("FAILED"))
//     NiceMock<MockLog>                                    a plain LogCapture / InMemoryLogSink, no expectations
//     Mock::VerifyAndClearExpectations(&log)               log.verify(…)             (checked after, on a capture you hold)
//     "Actual: never called" / "called twice"              "actual: never logged" / "logged 2 times", with the lines
//
// Two differences from gmock, on purpose:
//   * the verdict comes when the scope ENDS (or at `verify`), never at the
//     moment of the call: a log line is written from any thread and any task,
//     and a failure raised there would not be attributed to the test;
//   * the scope can WAIT, bounded, for expectations still outstanding, since
//     an OUTCOME line is often written one main-actor turn after the job's
//     task has ended. Only "not yet enough" is waited for (`.once`,
//     `.exactly(n)`, `.atLeast(n)`, `.inOrder`); `.never` and "too many" are
//     judged on what has been logged when the wait ends.
//
// This file imports no test framework (Core is linked into the app). It
// computes a `LogExpectationReport`; the ten-line shims in the two test
// targets (LogExpectationsTesting.swift, LogSinks+Test.swift) turn its one
// message into one `Issue.record` at the caller's line. Everything here is
// `@_spi(Testing)`: production cannot name it (LogScopeSensorTests).
//
// Memory: evaluation walks a snapshot of the capture's lines (the array is
// shared copy-on-write, not copied) and keeps, per expectation, a count and
// at most `LogExpectationReport.excerptLimit` (line number, line) pairs, each
// line cut to `lineLimit` characters. Worst case for the report text:
// expectations × excerptLimit × lineLimit characters (10 expectations: ~15 KB),
// whatever the capture holds. Time: one pass, lines × matchers (100 000 lines
// against five matchers: tens of milliseconds; LogExpectationScaleTests).

import Foundation
import os

// MARK: - Which line

/// A predicate on one log line that can describe itself in a failure message.
/// (C++: a gmock Matcher<const std::string&> — `Matches()` plus `DescribeTo()`.)
@_spi(Testing) public struct LogLineMatcher: Sendable, CustomStringConvertible {
    public let description: String
    private let test: @Sendable (String) -> Bool
    /// A literal the matcher looks for, when it has one: used only to find
    /// near misses for the failure message.
    let literal: String?

    init(_ description: String, literal: String? = nil, _ test: @escaping @Sendable (String) -> Bool) {
        self.description = description
        self.literal = literal
        self.test = test
    }

    public func matches(_ line: String) -> Bool { test(line) }

    /// HasSubstr.
    public static func contains(_ text: String) -> LogLineMatcher {
        LogLineMatcher("a line containing \(quoted(text))", literal: text) { $0.contains(text) }
    }

    /// Every one of `texts`, in any order (AllOf(HasSubstr…)).
    public static func containsAll(_ texts: [String]) -> LogLineMatcher {
        LogLineMatcher("a line containing all of " + texts.map(quoted).joined(separator: ", "),
                       literal: texts.max { $0.count < $1.count }) { line in texts.allSatisfy { line.contains($0) } }
    }

    /// AllOf: one line that satisfies every matcher
    /// (`.all(.hasPrefix("trim FAILED: "), .contains(stem))`).
    public static func all(_ matchers: LogLineMatcher...) -> LogLineMatcher {
        LogLineMatcher(matchers.map(\.description).joined(separator: " AND "),
                       literal: matchers.compactMap(\.literal).max { $0.count < $1.count }) { line in
            matchers.allSatisfy { $0.matches(line) }
        }
    }

    /// The whole line (Eq / StrEq).
    public static func equals(_ text: String) -> LogLineMatcher {
        LogLineMatcher("the line \(quoted(text))", literal: text) { $0 == text }
    }

    /// StartsWith.
    public static func hasPrefix(_ text: String) -> LogLineMatcher {
        LogLineMatcher("a line starting with \(quoted(text))", literal: text) { $0.hasPrefix(text) }
    }

    /// EndsWith.
    public static func hasSuffix(_ text: String) -> LogLineMatcher {
        LogLineMatcher("a line ending with \(quoted(text))", literal: text) { $0.hasSuffix(text) }
    }

    /// ContainsRegex: the regex is found somewhere in the line (anchor it
    /// with `^…$` to match the whole line). `label` replaces the pattern in
    /// the failure message when the regex was not written as a literal.
    ///
    /// `Regex` is not `Sendable`, and a matcher may be read from more than
    /// one task (a `static let` shared by a suite's parallel tests), so the
    /// regex sits behind its own lock; uncontended, that is a few
    /// nanoseconds a line.
    /// (C++: a `std::regex` guarded by a mutex because the type does not
    /// promise const-thread-safety.)
    public static func matching<Output>(_ regex: Regex<Output>, _ label: String? = nil) -> LogLineMatcher {
        let guarded = OSAllocatedUnfairLock<Regex<Output>>(uncheckedState: regex)
        // The pattern's text, for the message: readable only on macOS 15+
        // (the package's floor is 13; the test hosts run 15 or later).
        var pattern: String?
        if #available(macOS 15, *) { pattern = regex._literalPattern.map { "/\($0)/" } }
        let shown = label ?? pattern ?? "a regular expression"
        return LogLineMatcher("a line matching \(shown)") { line in
            guarded.withLockUnchecked { line.contains($0) }
        }
    }

    /// Truly(predicate): say in `description` what the predicate looks for;
    /// it is what the failure message prints.
    public static func line(_ description: String, where predicate: @escaping @Sendable (String) -> Bool) -> LogLineMatcher {
        LogLineMatcher("a line \(description)", predicate)
    }

    /// Any line at all (`_` in gmock).
    public static let anyLine = LogLineMatcher("any line") { _ in true }

    private static func quoted(_ text: String) -> String { "“\(text)”" }
}

// MARK: - How often, in what order

/// How many lines an expectation allows. (C++: gmock's Cardinality.)
@_spi(Testing) public enum LogTimes: Sendable, Equatable, CustomStringConvertible {
    case exactly(Int)
    case atLeast(Int)
    case atMost(Int)

    public static let once = LogTimes.exactly(1)
    public static let never = LogTimes.exactly(0)

    func allows(_ count: Int) -> Bool {
        switch self {
        case .exactly(let n): count == n
        case .atLeast(let n): count >= n
        case .atMost(let n): count <= n
        }
    }

    /// The count below which more lines could still make it true.
    var needed: Int {
        switch self {
        case .exactly(let n), .atLeast(let n): n
        case .atMost: 0
        }
    }

    public var description: String {
        switch self {
        case .exactly(0): "never"
        case .exactly(1): "once"
        case .exactly(let n): "exactly \(n) times"
        case .atLeast(1): "at least once"
        case .atLeast(let n): "at least \(n) times"
        case .atMost(1): "at most once"
        case .atMost(let n): "at most \(n) times"
        }
    }
}

/// One thing a test expects of its log. Build with the static functions;
/// each remembers the file and line it was written on, so the failure
/// message points at the expectation as gmock points at its EXPECT_CALL.
@_spi(Testing) public struct LogExpectation: Sendable, CustomStringConvertible {
    enum Kind: Sendable {
        case count(LogLineMatcher, LogTimes)
        case inOrder([LogLineMatcher])
        case noOtherLines(LogLineMatcher)
    }

    let kind: Kind
    /// "File.swift:42" — where the expectation was declared.
    public let declaredAt: String

    init(_ kind: Kind, _ fileID: String, _ line: Int) {
        self.kind = kind
        self.declaredAt = "\((fileID as NSString).lastPathComponent):\(line)"
    }

    // The gtest-shaped spellings: cardinality first, then the matcher.

    /// Times(1).
    public static func once(_ matcher: LogLineMatcher, fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(matcher, .once), fileID, line)
    }

    /// Times(n).
    public static func exactly(_ n: Int, _ matcher: LogLineMatcher, fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(matcher, .exactly(max(0, n))), fileID, line)
    }

    /// Times(AtLeast(n)).
    public static func atLeast(_ n: Int, _ matcher: LogLineMatcher, fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(matcher, .atLeast(max(0, n))), fileID, line)
    }

    /// Times(AtMost(n)).
    public static func atMost(_ n: Int, _ matcher: LogLineMatcher, fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(matcher, .atMost(max(0, n))), fileID, line)
    }

    /// Times(0).
    public static func never(_ matcher: LogLineMatcher, fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(matcher, .never), fileID, line)
    }

    // The same, matcher first: `.line(containing: "START", .once)`.

    public static func line(_ matcher: LogLineMatcher, _ times: LogTimes = .once,
                            fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(matcher, times), fileID, line)
    }

    public static func line(containing text: String, _ times: LogTimes = .once,
                            fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(.contains(text), times), fileID, line)
    }

    public static func line<Output>(matching regex: Regex<Output>, _ times: LogTimes = .once,
                                    fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.count(.matching(regex), times), fileID, line)
    }

    /// InSequence: a line for each matcher, each one AFTER the line that
    /// satisfied the matcher before it (START before OUTCOME). Other lines
    /// may come between. It says nothing about how often: pair it with
    /// `.once(…)` when a step must also not repeat.
    public static func inOrder(_ steps: [LogLineMatcher], fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.inOrder(steps), fileID, line)
    }

    public static func inOrder(_ steps: LogLineMatcher..., fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.inOrder(steps), fileID, line)
    }

    /// StrictMock: a line that satisfies `matcher` and that no other
    /// expectation in the same verification names (`.once`, `.exactly`,
    /// `.atLeast`, `.atMost` with a non-zero count, `.inOrder`) fails the
    /// test. The default is every line; narrow it to what must never slip
    /// by unnoticed: `.noOtherLines(matching: .contains("FAILED"))`.
    public static func noOtherLines(matching matcher: LogLineMatcher = .anyLine,
                                    fileID: String = #fileID, line: Int = #line) -> LogExpectation {
        LogExpectation(.noOtherLines(matcher), fileID, line)
    }

    public var description: String {
        switch kind {
        case .count(let matcher, let times): "\(times): \(matcher)"
        case .inOrder(let steps):
            "in order: " + steps.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: ", then ")
        case .noOtherLines(let matcher):
            "no other lines: \(matcher), unless another expectation names it"
        }
    }

    /// The matchers whose lines this expectation accounts for (for
    /// `noOtherLines`): everything it expects to SEE.
    var claims: [LogLineMatcher] {
        switch kind {
        case .count(let matcher, let times): times == .never ? [] : [matcher]
        case .inOrder(let steps): steps
        case .noOtherLines: []
        }
    }
}

// MARK: - The verdict

/// What a verification found. `message` is nil when every expectation is met.
@_spi(Testing) public struct LogExpectationReport: Sendable {
    /// One unmet or violated expectation.
    public struct Failure: Sendable {
        public let expectation: String
        public let declaredAt: String
        /// "never logged", "logged 2 times", "step 2 never came after step 1" …
        public let actual: String
        /// The captured lines that show it, "[line number] text", bounded.
        public let excerpt: [String]
    }

    /// Lines quoted per failure, and characters per quoted line.
    public static let excerptLimit = 5
    public static let lineLimit = 300

    public let failures: [Failure]
    public let expectationCount: Int
    public let lineCount: Int
    /// True when at least one expectation could still be met by lines that
    /// have not been logged yet (what the bounded wait waits for).
    public let hasOutstanding: Bool

    public var isMet: Bool { failures.isEmpty }

    /// The ONE message for the one issue; nil when met.
    public var message: String? {
        guard !failures.isEmpty else { return nil }
        var out = ["log expectations not met: \(failures.count) of \(expectationCount) (\(lineCount) line\(lineCount == 1 ? "" : "s") captured)"]
        for f in failures {
            out.append("  - expected \(f.expectation)   [\(f.declaredAt)]")
            out.append("      actual: \(f.actual)")
            out += f.excerpt.map { "        \($0)" }
        }
        return out.joined(separator: "\n")
    }
}

/// How captured lines are quoted in a failure: by 1-based line number, cut
/// to `lineLimit`, at most `excerptLimit` of them. (The bound on the report.)
struct LogExcerpt {
    let lines: [String]
    var limit: Int { LogExpectationReport.excerptLimit }

    func quote(_ index: Int) -> String {
        let line = lines[index]
        let cut = line.count > LogExpectationReport.lineLimit
            ? String(line.prefix(LogExpectationReport.lineLimit)) + "… (\(line.count) characters)" : line
        return "[\(index + 1)] \(cut)"
    }

    /// The quoted lines at `indexes` (already at most `limit`), and how many more there were.
    func quoteAll(_ indexes: [Int], of total: Int) -> [String] {
        indexes.map(quote) + (total > indexes.count ? ["… and \(total - indexes.count) more"] : [])
    }

    /// What to show when an expected line is absent: lines that share the
    /// matcher's longest word (a near miss — the wording drifted), else the
    /// last lines captured.
    func nearMisses(_ matcher: LogLineMatcher) -> [String] {
        if lines.isEmpty { return ["(nothing was logged in this scope)"] }
        let words: [Substring] = (matcher.literal ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if let word = words.filter({ $0.count >= 4 }).max(by: { $0.count < $1.count }).map({ String($0) }) {
            let near = Array(lines.indices.lazy.filter { lines[$0].localizedCaseInsensitiveContains(word) }.prefix(limit))
            if !near.isEmpty { return ["nearest (lines with “\(word)”):"] + near.map(quote) }
        }
        let tail = Array(max(0, lines.count - limit)..<lines.count)
        return ["the last \(tail.count) of \(lines.count) captured:"] + tail.map(quote)
    }
}

/// What ONE pass over the lines saw, per expectation: how many lines it
/// accounts for, the first few of them, and (for `.inOrder`) the line each
/// step was satisfied at.
struct LogTally {
    var counts: [Int]
    var seen: [[Int]]
    var stepsDone: [[Int]]

    init(_ expectations: [LogExpectation], lines: [String]) {
        counts = [Int](repeating: 0, count: expectations.count)
        seen = [[Int]](repeating: [], count: expectations.count)
        stepsDone = [[Int]](repeating: [], count: expectations.count)
        let claimed = expectations.flatMap(\.claims)
        for (index, line) in lines.enumerated() {
            for (e, expectation) in expectations.enumerated() where accounts(expectation, e, for: line, claimed: claimed, at: index) {
                counts[e] += 1
                if seen[e].count < LogExpectationReport.excerptLimit { seen[e].append(index) }
            }
        }
    }

    /// Does `line` count toward expectation `e`? (An `.inOrder` step is
    /// recorded here and never counted: order is not cardinality.)
    private mutating func accounts(_ expectation: LogExpectation, _ e: Int, for line: String,
                                   claimed: [LogLineMatcher], at index: Int) -> Bool {
        switch expectation.kind {
        case .count(let matcher, _):
            return matcher.matches(line)
        case .inOrder(let steps):
            let next = stepsDone[e].count
            if next < steps.count, steps[next].matches(line) { stepsDone[e].append(index) }
            return false
        case .noOtherLines(let matcher):
            return matcher.matches(line) && !claimed.contains { $0.matches(line) }
        }
    }
}

@_spi(Testing) public enum LogExpectations {

    /// Judge `lines` against `expectations`. Pure: no clock, no capture.
    /// `dropped` is the capture's count of lines refused at its bound; a
    /// verdict on a log that lost lines would be a guess, so it is a failure.
    public static func evaluate(_ expectations: [LogExpectation], lines: [String], dropped: Int = 0) -> LogExpectationReport {
        let tally = LogTally(expectations, lines: lines)
        let excerpt = LogExcerpt(lines: lines)
        var failures: [LogExpectationReport.Failure] = []
        var outstanding = false
        for (e, expectation) in expectations.enumerated() {
            let verdict: Verdict
            switch expectation.kind {
            case .count(let matcher, let wanted):
                verdict = judgeCount(matcher, wanted, logged: tally.counts[e], at: tally.seen[e], excerpt)
            case .inOrder(let steps):
                verdict = judgeOrder(steps, done: tally.stepsDone[e], excerpt)
            case .noOtherLines:
                verdict = judgeStrict(unexpected: tally.counts[e], at: tally.seen[e], excerpt)
            }
            outstanding = outstanding || verdict.outstanding
            if let actual = verdict.actual {
                failures.append(.init(expectation: expectation.description, declaredAt: expectation.declaredAt,
                                      actual: actual, excerpt: verdict.excerpt))
            }
        }
        if dropped > 0 {
            failures.append(.init(expectation: "a complete log", declaredAt: "LogCapture",
                                  actual: "the capture reached its bound and dropped \(dropped) line(s); a verdict on the first \(lines.count) would be a guess",
                                  excerpt: []))
        }
        return LogExpectationReport(failures: failures, expectationCount: expectations.count,
                                    lineCount: lines.count, hasOutstanding: outstanding)
    }

    /// One expectation's verdict: `actual` is nil when it is met;
    /// `outstanding` when a line not yet logged could still meet it.
    struct Verdict {
        var actual: String?
        var excerpt: [String] = []
        var outstanding = false
        static let met = Verdict()
    }

    /// Cardinality (gmock's "Actual: never called / called twice").
    static func judgeCount(_ matcher: LogLineMatcher, _ wanted: LogTimes, logged n: Int, at seen: [Int],
                           _ excerpt: LogExcerpt) -> Verdict {
        let outstanding = n < wanted.needed
        if wanted.allows(n) { return Verdict(outstanding: outstanding) }
        if n == 0 { return Verdict(actual: "never logged", excerpt: excerpt.nearMisses(matcher), outstanding: outstanding) }
        return Verdict(actual: "logged \(n == 1 ? "1 time" : "\(n) times")", excerpt: excerpt.quoteAll(seen, of: n),
                       outstanding: outstanding)
    }

    /// Order (InSequence): which step never came after the one before it —
    /// and, when it was logged only too early, that line.
    static func judgeOrder(_ steps: [LogLineMatcher], done: [Int], _ excerpt: LogExcerpt) -> Verdict {
        guard done.count < steps.count else { return .met }
        let missing = done.count
        let step = "step \(missing + 1) (\(steps[missing]))"
        let after = done.last.map { " after step \(missing) (line \($0 + 1))" } ?? ""
        var shown = done.enumerated().map { "step \($0.offset + 1) at " + excerpt.quote($0.element) }
        let early = done.last.flatMap { bound in excerpt.lines[..<bound].firstIndex { steps[missing].matches($0) } }
        if let early {
            shown.append("step \(missing + 1) only BEFORE it, at " + excerpt.quote(early))
            return Verdict(actual: "\(step) was logged out of order: never\(after)", excerpt: shown, outstanding: true)
        }
        if done.isEmpty { shown += excerpt.nearMisses(steps[missing]) }
        return Verdict(actual: "\(step) was never logged\(after)", excerpt: shown, outstanding: true)
    }

    /// Strictness (StrictMock): lines nothing else accounts for.
    static func judgeStrict(unexpected n: Int, at seen: [Int], _ excerpt: LogExcerpt) -> Verdict {
        n == 0 ? .met : Verdict(actual: "\(n) unexpected line\(n == 1 ? "" : "s")", excerpt: excerpt.quoteAll(seen, of: n))
    }

    /// The verifying scope, framework-free: bind `capture` for `body`, wait
    /// up to `timeout` for expectations still outstanding, and hand the one
    /// failure message (if any) to `report`. When `body` throws, what was
    /// logged so far is judged at once (no wait) and the error is rethrown —
    /// as gmock verifies in the mock's destructor during unwinding.
    /// The test targets wrap this as `expectingLog(…)` with `report` =
    /// `Issue.record` at the caller's source location.
    /// `binding`: the sink to bind when it is not the capture itself — the
    /// app's `InMemoryLogSink`, a `LogSink` that records into `capture`.
    public static func run<R>(
        _ expectations: [LogExpectation],
        capture: LogCapture,
        binding: (any TaskScopedLogSink)? = nil,
        waitingUpTo timeout: Duration,
        isolation: isolated (any Actor)? = #isolation,
        report: (String) -> Void,
        _ body: () async throws -> R
    ) async rethrows -> R {
        let value: R
        do {
            value = try await LogScope.with(binding ?? capture, isolation: isolation, body)
        } catch {
            if let message = capture.check(expectations).message {
                report(message + "\n  (judged when the body threw: \(error))")
            }
            throw error
        }
        if let message = await capture.check(expectations, waitingUpTo: timeout, isolation: isolation).message {
            report(message)
        }
        return value
    }
}

extension LogCapture {
    /// Judge what has been captured so far. No waiting, no issue recorded:
    /// the framework-free core of `verify`.
    @_spi(Testing) public func check(_ expectations: [LogExpectation]) -> LogExpectationReport {
        LogExpectations.evaluate(expectations, lines: lines, dropped: droppedCount)
    }

    /// Judge, first waiting up to `timeout` while some expectation could
    /// still be met by a line not yet logged. Polls every 5 ms (each poll
    /// suspends, so a `@MainActor` caller lets the main-actor hop that
    /// writes an OUTCOME run) and re-judges only when a line has arrived.
    /// A verdict that is already final returns without waiting.
    @_spi(Testing) public func check(
        _ expectations: [LogExpectation],
        waitingUpTo timeout: Duration,
        isolation: isolated (any Actor)? = #isolation
    ) async -> LogExpectationReport {
        var judged = count
        var report = check(expectations)
        let deadline = ContinuousClock.now + timeout
        while report.hasOutstanding, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            let now = count
            if now != judged {
                judged = now
                report = check(expectations)
            }
        }
        return report
    }
}
