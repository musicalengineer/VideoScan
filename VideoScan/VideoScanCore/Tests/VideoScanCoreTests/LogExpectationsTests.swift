// LogExpectationsTests.swift
// The expectation layer over LogCapture (Sources/VideoScanCore/LogExpectations.swift):
// each cardinality and each order violation produces the right words; the
// excerpt quotes the REAL offending line; one scope records ONE issue at the
// caller's line; two scopes running at once never judge each other's lines;
// 100 000 captured lines are judged inside a budget.

import Foundation
import Testing
@_spi(Testing) @testable import VideoScanCore

/// What production's `appLog.write` does, in miniature: the scoped sink.
private func log(_ line: String) { LogScope.current?.write(line) }

private func judge(_ lines: [String], _ expectations: LogExpectation...) -> LogExpectationReport {
    LogExpectations.evaluate(expectations, lines: lines)
}

/// Counts the issues a `withKnownIssue` matcher is shown and keeps their text.
private final class IssueLog: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var lineNumbers: [Int] = []
    func add(_ issue: Issue) {
        lock.lock(); defer { lock.unlock() }
        texts.append(issue.comments.map(\.rawValue).joined(separator: "\n"))
        lineNumbers.append(issue.sourceLocation?.line ?? -1)
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return texts }
    var lines: [Int] { lock.lock(); defer { lock.unlock() }; return lineNumbers }
}

@Suite("LogExpectations — logic: cardinality, order, strictness, and the words of each failure")
struct LogExpectationsLogicTests {

    static let transcript = [
        "transcode: tape.mov — archival → tape_archival.mov",
        "transcode watchdog: tape.mov stalled 300s during transcode encode",
        "transcode FAILED: tape.mov — Stalled",
    ]

    @Test("met: every cardinality that holds says nothing")
    func metExpectationsAreSilent() {
        let report = judge(Self.transcript,
                           .once(.hasPrefix("transcode: ")),
                           .exactly(3, .contains("tape.mov")),
                           .atLeast(2, .contains("transcode")),
                           .atMost(1, .contains("watchdog")),
                           .never(.contains("Transcoded")),
                           .line(containing: "FAILED"),
                           .line(matching: /^transcode FAILED: .* Stalled$/, .once),
                           .inOrder(.hasPrefix("transcode: "), .contains("watchdog"), .hasPrefix("transcode FAILED: ")),
                           .noOtherLines(matching: .contains("FAILED")))
        #expect(report.isMet)
        #expect(report.message == nil)
        #expect(!report.hasOutstanding)
    }

    @Test(".once on a line never logged: 'never logged', with the nearest lines")
    func onceNeverLogged() throws {
        let report = judge(Self.transcript, .once(.contains("START transcode")))
        let message = try #require(report.message)
        #expect(message.contains("log expectations not met: 1 of 1 (3 lines captured)"), "\(message)")
        #expect(message.contains("- expected once: a line containing “START transcode”"), "\(message)")
        #expect(message.contains("LogExpectationsTests.swift:"), "the expectation's own file and line: \(message)")
        #expect(message.contains("actual: never logged"), "\(message)")
        // The near miss: the wording drifted, the lines that share its longest word are shown.
        #expect(message.contains("nearest (lines with “transcode”):"), "\(message)")
        #expect(message.contains("[1] transcode: tape.mov — archival → tape_archival.mov"), "\(message)")
        #expect(report.hasOutstanding, "a later line could still meet it")
    }

    @Test(".once on a line logged twice: 'logged 2 times', both lines quoted with their numbers")
    func onceLoggedTwice() throws {
        let report = judge(["a", "trim done: x.mov — ok", "b", "trim done: x.mov — ok"], .once(.hasPrefix("trim done: ")))
        let message = try #require(report.message)
        #expect(message.contains("- expected once: a line starting with “trim done: ”"), "\(message)")
        #expect(message.contains("actual: logged 2 times"), "\(message)")
        #expect(message.contains("[2] trim done: x.mov — ok"), "\(message)")
        #expect(message.contains("[4] trim done: x.mov — ok"), "\(message)")
        #expect(!report.hasOutstanding, "too many is final: nothing to wait for")
    }

    @Test(".exactly / .atLeast / .atMost / .never: each says what it wanted and what it got")
    func theOtherCardinalities() throws {
        let lines = ["x 1", "x 2", "y"]
        var m = try #require(judge(lines, .exactly(3, .contains("x"))).message)
        #expect(m.contains("expected exactly 3 times: a line containing “x”") && m.contains("actual: logged 2 times"), "\(m)")
        m = try #require(judge(lines, .atLeast(3, .contains("x"))).message)
        #expect(m.contains("expected at least 3 times: a line containing “x”") && m.contains("actual: logged 2 times"), "\(m)")
        m = try #require(judge(lines, .atMost(1, .contains("x"))).message)
        #expect(m.contains("expected at most once: a line containing “x”") && m.contains("actual: logged 2 times"), "\(m)")
        m = try #require(judge(lines, .never(.equals("y"))).message)
        #expect(m.contains("expected never: the line “y”") && m.contains("actual: logged 1 time\n") && m.contains("[3] y"), "\(m)")
        m = try #require(judge(lines, .line(containing: "y", .never)).message)
        #expect(m.contains("expected never: a line containing “y”"), "\(m)")
        #expect(judge(lines, .exactly(2, .contains("x")), .atLeast(1, .contains("y")), .atMost(2, .contains("x"))).isMet)
    }

    @Test("truth: the excerpt is the real offending line, by its real line number — not a paraphrase")
    func theExcerptShowsTheRealOffendingLine() throws {
        var lines = (1...40).map { "verify: file \($0) ok" }
        lines[26] = "verify FAILED: IMG_0027.mov — SHA-256 differs (expected 9f2c…, read 0b71…)"
        let report = judge(lines, .never(.contains("FAILED")), .noOtherLines(matching: .contains("FAILED")))
        let message = try #require(report.message)
        #expect(message.contains("[27] verify FAILED: IMG_0027.mov — SHA-256 differs (expected 9f2c…, read 0b71…)"), "\(message)")
        #expect(report.failures.count == 2)
        #expect(report.failures.allSatisfy { $0.excerpt == ["[27] " + lines[26]] }, "\(report.failures)")
        #expect(!message.contains("file 26 ok"), "only the mismatch is quoted, not its neighbours")
    }

    @Test(".inOrder: START before OUTCOME holds with other lines between")
    func inOrderHolds() {
        #expect(judge(Self.transcript, .inOrder([.hasPrefix("transcode: "), .hasPrefix("transcode FAILED: ")])).isMet)
    }

    @Test(".inOrder: OUTCOME logged before START says 'out of order' and quotes the early line")
    func inOrderViolated() throws {
        let lines = ["compare done: a vs b — identical", "noise", "compare: a vs b — duplicate check"]
        let report = judge(lines, .inOrder(.hasPrefix("compare: "), .hasPrefix("compare done: ")))
        let message = try #require(report.message)
        #expect(message.contains("expected in order: [1] a line starting with “compare: ”, then [2] a line starting with “compare done: ”"), "\(message)")
        #expect(message.contains("actual: step 2 (a line starting with “compare done: ”) was logged out of order: never after step 1 (line 3)"), "\(message)")
        #expect(message.contains("step 1 at [3] compare: a vs b — duplicate check"), "\(message)")
        #expect(message.contains("step 2 only BEFORE it, at [1] compare done: a vs b — identical"), "\(message)")
    }

    @Test(".inOrder: a step that never comes is named, with the steps that did")
    func inOrderStepMissing() throws {
        let report = judge(Self.transcript, .inOrder(.hasPrefix("transcode: "), .contains("watchdog"), .hasPrefix("transcode done: ")))
        let message = try #require(report.message)
        #expect(message.contains("actual: step 3 (a line starting with “transcode done: ”) was never logged after step 2 (line 2)"), "\(message)")
        #expect(message.contains("step 2 at [2] transcode watchdog"), "\(message)")
        #expect(report.hasOutstanding)
        // …and a first step that never comes shows the near misses.
        let first = try #require(judge(Self.transcript, .inOrder(.hasPrefix("START transcode"), .contains("FAILED"))).message)
        #expect(first.contains("actual: step 1 (a line starting with “START transcode”) was never logged"), "\(first)")
        #expect(first.contains("nearest (lines with “transcode”):"), "\(first)")
    }

    @Test(".inOrder does not count: a repeated step is the job of .once")
    func inOrderIsNotCardinality() {
        let lines = ["trim: a", "trim: a", "trim done: a"]
        #expect(judge(lines, .inOrder(.hasPrefix("trim: "), .hasPrefix("trim done: "))).isMet)
        #expect(!judge(lines, .inOrder(.hasPrefix("trim: "), .hasPrefix("trim done: ")), .once(.hasPrefix("trim: "))).isMet)
    }

    @Test(".noOtherLines (StrictMock): an unexpected FAILED line fails; one another expectation names does not")
    func strictMode() throws {
        let lines = ["trim: a.mov — 0:00–0:01", "trim FAILED: a.mov — Source file missing", "cleanup FAILED: b.mov — no ffmpeg"]
        let strict = LogExpectation.noOtherLines(matching: .contains("FAILED"))
        #expect(judge(Array(lines.prefix(2)), .once(.hasPrefix("trim FAILED: ")), strict).isMet)
        let message = try #require(judge(lines, .once(.hasPrefix("trim FAILED: ")), strict).message)
        #expect(message.contains("expected no other lines: a line containing “FAILED”, unless another expectation names it"), "\(message)")
        #expect(message.contains("actual: 1 unexpected line"), "\(message)")
        #expect(message.contains("[3] cleanup FAILED: b.mov — no ffmpeg"), "\(message)")
        #expect(!message.contains("[2] trim FAILED"), "the expected line is not reported: \(message)")
        // A `.never` does not excuse a line: it names what must NOT be seen.
        #expect(judge(lines, .never(.contains("cleanup FAILED")), strict).failures.count == 2)
        // The default is every line, like a StrictMock with no ON_CALL.
        let all = try #require(judge(lines, .once(.hasPrefix("trim: ")), .noOtherLines()).message)
        #expect(all.contains("actual: 2 unexpected lines") && all.contains("[2] trim FAILED") && all.contains("[3] cleanup FAILED"), "\(all)")
        #expect(judge(lines, .atLeast(1, .anyLine), .noOtherLines()).isMet)
    }

    @Test("matchers: equals, hasSuffix, containsAll, a regex, a predicate — and how each describes itself")
    func matchers() {
        let line = "balance audio refused: Clip 28.dv — already running"
        #expect(LogLineMatcher.equals(line).matches(line) && !LogLineMatcher.equals("balance").matches(line))
        #expect(LogLineMatcher.hasSuffix("already running").matches(line))
        #expect(LogLineMatcher.containsAll(["refused", "Clip 28.dv"]).matches(line) && !LogLineMatcher.containsAll(["refused", "Clip 29"]).matches(line))
        #expect(LogLineMatcher.matching(/refused: .* — already/).matches(line) && !LogLineMatcher.matching(/^refused/).matches(line))
        #expect(LogLineMatcher.line("over 40 characters") { $0.count > 40 }.matches(line))
        let both = LogLineMatcher.all(.hasPrefix("balance audio refused: "), .contains("already running"))
        #expect(both.matches(line) && !both.matches("trim refused: x — already running"))
        #expect(both.description == "a line starting with “balance audio refused: ” AND a line containing “already running”")
        #expect(LogLineMatcher.containsAll(["a", "b"]).description == "a line containing all of “a”, “b”")
        #expect(LogLineMatcher.line("over 40 characters") { $0.count > 40 }.description == "a line over 40 characters")
        #expect(LogLineMatcher.matching(/x+/, "one or more x").description == "a line matching one or more x")
        if #available(macOS 15, *) {
            #expect(LogLineMatcher.matching(/OUTCOME .* FAILED/).description == "a line matching /OUTCOME .* FAILED/")
        }
    }

    @Test("bounded: 1 000 offending lines quote five and count the rest; a 10 000-character line is cut to 300")
    func theExcerptIsBounded() throws {
        let flood = (0..<1_000).map { "ERROR \($0) " + String(repeating: "x", count: 10_000) }
        let report = judge(flood, .never(.hasPrefix("ERROR")))
        let failure = try #require(report.failures.first)
        #expect(failure.actual == "logged 1000 times")
        #expect(failure.excerpt.count == LogExpectationReport.excerptLimit + 1)
        #expect(failure.excerpt.last == "… and 995 more")
        #expect(failure.excerpt[0].hasPrefix("[1] ERROR 0 xxx") && failure.excerpt[0].hasSuffix("… (10008 characters)"), "\(failure.excerpt[0].suffix(40))")
        #expect((report.message ?? "").count < 5 * 400 + 600, "the message is bounded whatever the capture holds: \((report.message ?? "").count)")
    }

    @Test("nothing logged at all says so")
    func emptyLog() throws {
        let message = try #require(judge([], .once(.contains("START"))).message)
        #expect(message.contains("(0 lines captured)") && message.contains("(nothing was logged in this scope)"), "\(message)")
        #expect(judge([], .never(.anyLine), .noOtherLines()).isMet)
    }

    @Test("a capture that dropped lines at its bound cannot vouch for .never: the verdict is a failure that says so")
    func droppedLinesAreNotAVerdict() throws {
        let capture = LogCapture(maxLines: 3)
        for n in 0..<5 { capture.write("line \(n)") }
        let report = capture.check([.never(.contains("FAILED"))])
        let message = try #require(report.message)
        #expect(message.contains("dropped 2 line(s)"), "\(message)")
    }
}

@Suite("LogExpectations — the verifying scope: one issue, at the caller's line, never a crash")
struct LogExpectingScopeTests {

    @Test("a met scope records nothing and returns the body's value and the capture")
    func metScopeReturnsValueAndCapture() async throws {
        let (value, captured) = await expectingLog(
            .once(.hasPrefix("compare: ")),
            .once(.hasPrefix("compare done: ")),
            .inOrder(.hasPrefix("compare: "), .hasPrefix("compare done: ")),
            .noOtherLines(matching: .contains("FAILED"))
        ) {
            log("compare: a vs b — duplicate check")
            log("compare done: a vs b — identical")
            return 42
        }
        #expect(value == 42)
        #expect(captured.lines.count == 2, "the capture is there for ad hoc assertions")
        #expect(LogScope.current == nil, "the binding ended with the scope")
    }

    @Test("three unmet expectations are ONE issue, at the line of the expectingLog call")
    func oneIssueForEverythingUnmet() async {
        let issues = IssueLog()
        let callLine = #line + 2
        await withKnownIssue {
            await expectingLog(
                .once(.contains("START transcode")),
                .once(.matching(/^transcode FAILED: .* exit code 228/)),
                .never(.contains("Transcoded")),
                .once(.hasPrefix("transcode: ")),
                waitingUpTo: .zero
            ) {
                log("transcode: tape.mov — archival → tape_archival.mov")
                log("transcode done: tape.mov — Transcoded to FFV1")
            }
        } matching: { issue in
            issues.add(issue)
            return true
        }
        #expect(issues.all.count == 1, "one issue, not one per expectation: \(issues.all)")
        #expect(issues.lines == [callLine], "reported at the call, as #expect would be")
        let text = issues.all.first ?? ""
        #expect(text.contains("log expectations not met: 3 of 4 (2 lines captured)"), "\(text)")
        #expect(text.contains("expected once: a line containing “START transcode”") && text.contains("actual: never logged"), "\(text)")
        #expect(text.contains("expected never: a line containing “Transcoded”") && text.contains("[2] transcode done: tape.mov — Transcoded to FFV1"), "\(text)")
        #expect(!text.contains("expected once: a line starting with “transcode: ”"), "a met expectation is not listed: \(text)")
    }

    @Test("checked after: verify on a capture the test holds records one issue the same way")
    func verifyAfterTheFact() async {
        let capture = LogCapture()
        capture.scoped { log("trim: a.mov"); log("trim cancelled: a.mov") }
        #expect(capture.verify(.once(.hasPrefix("trim: ")), .never(.contains("FAILED"))))
        let issues = IssueLog()
        withKnownIssue {
            #expect(!capture.verify(.once(.hasPrefix("trim done: ")), .never(.contains("cancelled"))))
        } matching: { issues.add($0); return true }
        #expect(issues.all.count == 1)
        #expect(issues.all.first?.contains("not met: 2 of 2") == true, "\(issues.all)")
        await withKnownIssue {
            _ = await capture.verify(.once(.hasPrefix("trim done: ")), waitingUpTo: .milliseconds(20))
        } matching: { $0.comments.contains { $0.rawValue.contains("actual: never logged") } }
    }

    @Test("a body that throws: the error comes out, and what was logged so far is still judged, at once")
    func aThrowingBodyIsStillVerified() async {
        struct Boom: Error {}
        let issues = IssueLog()
        await withKnownIssue {
            await #expect(throws: Boom.self) {
                try await expectingLog(.once(.contains("OUTCOME")), waitingUpTo: .seconds(600)) {
                    log("START")
                    throw Boom()
                }
            }
        } matching: { issues.add($0); return true }
        #expect(issues.all.count == 1)
        #expect(issues.all.first?.contains("(judged when the body threw: Boom())") == true, "\(issues.all)")
        #expect(LogScope.current == nil)
    }

    @Test("the bounded wait: an OUTCOME written after the body returned (from a task that carries the scope) is met")
    func waitsForALineStillToCome() async {
        let (_, captured) = await expectingLog(
            .once(.equals("START")),
            .once(.equals("OUTCOME")),
            .inOrder(.equals("START"), .equals("OUTCOME")),
            waitingUpTo: .seconds(60)
        ) {
            log("START")
            _ = TaskTreeScope.detached {
                try? await Task.sleep(for: .milliseconds(60))
                log("OUTCOME")
            }
        }
        #expect(captured.lines == ["START", "OUTCOME"])
    }

    @Test("the wait is only for 'not yet enough': a verdict that is already final has nothing outstanding")
    func aFinalVerdictDoesNotWait() async {
        let capture = LogCapture()
        capture.scoped { log("x"); log("x"); log("FAILED") }
        // Too many, a forbidden line, an unexpected line: more lines cannot help.
        let final = capture.check([.once(.equals("x")), .never(.contains("FAILED")), .noOtherLines()])
        #expect(!final.isMet && !final.hasOutstanding)
        // With the 10-minute timeout this returns at once or the suite's time limit fails it.
        let waited = await capture.check([.once(.equals("x")), .never(.contains("FAILED"))], waitingUpTo: .seconds(600))
        #expect(waited.failures.count == 2)
        #expect(capture.check([.exactly(3, .equals("x"))]).hasOutstanding)
        #expect(capture.check([.inOrder(.equals("FAILED"), .equals("x"))]).hasOutstanding)
    }
}

@Suite("LogExpectations — isolation and scale")
struct LogExpectationsIsolationAndScaleTests {

    /// 32 cases run at once; each expects exactly its own lines and forbids
    /// every other line, while the others log beside it.
    @Test("isolation: 32 concurrent expecting scopes, each strict — none sees a line of another", arguments: 0..<32)
    func concurrentScopesNeverSeeEachOther(_ id: Int) async {
        let tag = "case-\(id)-\(UUID().uuidString)"
        let (_, captured) = await expectingLog(
            .once(.equals("\(tag) START")),
            .exactly(8 * 50, .hasPrefix("\(tag) child ")),
            .once(.equals("\(tag) OUTCOME")),
            .inOrder(.equals("\(tag) START"), .equals("\(tag) OUTCOME")),
            .never(.line("from another scope") { !$0.hasPrefix(tag) }),
            .noOtherLines(),
            waitingUpTo: .zero
        ) {
            log("\(tag) START")
            await withTaskGroup(of: Void.self) { group in
                for child in 0..<8 {
                    group.addTask {
                        for n in 0..<50 {
                            log("\(tag) child \(child) line \(n)")
                            if n % 10 == 0 { await Task.yield() }
                        }
                    }
                }
            }
            log("\(tag) OUTCOME")
        }
        #expect(captured.count == 8 * 50 + 2)
    }

    @Test("isolation: a line logged outside any scope, or in a nested scope, is not this scope's line")
    func nestedAndUnscopedLines() async {
        log("before any scope")
        let (_, outer) = await expectingLog(.once(.equals("outer")), .noOtherLines(), waitingUpTo: .zero) {
            log("outer")
            await expectingLog(.once(.equals("inner")), .noOtherLines(), waitingUpTo: .zero) { log("inner") }
        }
        #expect(outer.lines == ["outer"])
    }

    /// Scale: a job that logs a line per file over a 100k catalog. Six
    /// expectations (a regex among them) are judged in one pass. Measured
    /// 2026-11-21, Debug, the Ultra under other agents' builds: see the
    /// printed line; the budget is ~10x that.
    @Test("scale: 100 000 captured lines are verified within 4 s, and a failure among them still quotes five lines",
          .tags(.quietMachine))   // judges a wall-time budget: the serial phase (QuietMachine.swift)
    func oneHundredThousandLines() async {
        let capture = LogCapture()
        capture.write("verify: 100000 files — START")
        for n in 1...100_000 {
            capture.write("verify: /Volumes/Archive/1990s/IMG_\(n).mov sha256 ok (\(n) of 100000)")
        }
        capture.write("verify done: 100000 files — 100000 ok, 0 failed")
        let expectations: [LogExpectation] = [
            .once(.hasSuffix("— START")),
            .exactly(100_000, .contains("sha256 ok")),
            .once(.hasPrefix("verify done: ")),
            .inOrder(.hasSuffix("— START"), .contains("(100000 of 100000)"), .hasPrefix("verify done: ")),
            .never(.matching(/sha256 (differs|unreadable)/)),
            .noOtherLines(matching: .contains("FAILED:")),
        ]
        let loadBefore = TimingBudget.sampleLoad()
        var report = capture.check(expectations)
        let elapsed = ContinuousClock().measure { report = capture.check(expectations) }
        print("LogExpectations: 6 expectations over \(capture.count) lines judged in \(elapsed)")
        #expect(report.isMet, "\(report.message ?? "")")
        expectWithinTimingBudget("LogExpectations 100k lines × 6 expectations", measured: elapsed,
                                 budget: .seconds(4), loadBefore: loadBefore)
        // And the failing shape at scale stays bounded.
        let bad = capture.check([.never(.contains("sha256 ok"))])
        #expect(bad.failures.first?.actual == "logged 100000 times")
        #expect((bad.message ?? "").count < 2_000, "\((bad.message ?? "").count)")
    }
}

@Suite("LogExpectations — sensors")
struct LogExpectationsSensorTests {

    /// LogExpectations.swift lives in Core's SOURCES (both test targets use
    /// it), and LogScopeSensorTests lets it name LogCapture and bind a scope.
    /// That exemption is safe only while production cannot reach anything in
    /// it: every declaration it exports must be `@_spi(Testing)`, or sit
    /// inside a type that is.
    static func exportsOutsideTheTestingSPI(_ text: String) -> [String] {
        var hits: [String] = []
        var inExtension = false     // `extension LogCapture {` — a public type: its members need the SPI themselves
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.hasPrefix("extension ") { inExtension = true }
            if line == "}" { inExtension = false }
            let topLevel = !line.hasPrefix(" ") && !line.hasPrefix("//")
            let memberOfAnExtension = inExtension && line.hasPrefix("    ") && !line.hasPrefix("     ")
            guard topLevel || memberOfAnExtension else { continue }
            if line.range(of: #"\bpublic\b"#, options: .regularExpression) != nil, !line.contains("@_spi(Testing)") {
                hits.append("\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return hits
    }

    @Test("sensor: everything LogExpectations.swift exports is @_spi(Testing), and it imports no test framework")
    func theLayerIsTestingSPIOnly() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/LogExpectations.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "@_spi(Testing) public").count > 6, "the scan found the file's declarations")
        #expect(Self.exportsOutsideTheTestingSPI(text).isEmpty, "\(Self.exportsOutsideTheTestingSPI(text))")
        let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init)
        #expect(imports == ["import Foundation", "import os"], "Core is linked into the app: no Testing, no XCTest — \(imports)")
    }

    @Test("sensor: the rule catches a plain public export at top level and in an extension, and ignores nested members")
    func theRuleCatchesItsOwnMutation() {
        #expect(Self.exportsOutsideTheTestingSPI("public struct Door {}") == ["1: public struct Door {}"])
        #expect(Self.exportsOutsideTheTestingSPI("extension LogCapture {\n    public func open() {}\n}") == ["2: public func open() {}"])
        #expect(Self.exportsOutsideTheTestingSPI("@_spi(Testing) public struct M {\n    public let description: String\n}").isEmpty)
        #expect(Self.exportsOutsideTheTestingSPI("extension LogCapture {\n    @_spi(Testing) public func check() {}\n}").isEmpty)
        #expect(Self.exportsOutsideTheTestingSPI("// public in a comment\nprivate func f() {}").isEmpty)
    }
}
