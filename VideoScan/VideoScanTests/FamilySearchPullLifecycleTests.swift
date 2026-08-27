// FamilySearchPullLifecycleTests.swift
// SENSORS for codex #707 items 2 and 3 (2026-08-26).
//
// Item 2 — the parse used to be a fire-and-forget `Task { await finish() }`
// nobody owned: forget() during it still published `.ready` into a dead
// coordinator, and two rapid parses raced. The coordinator now owns the
// parse task and gates its result on a generation counter.
//
// Item 3 — a run that paused > 30 s with no trailer was declared FAILED.
// getmyancestors pauses for the password prompt and between pages; a pause
// is now a soft `quietSince` note and the watcher keeps watching. Only the
// file disappearing (after we had seen it) is failure.
//
// All tests inject a silent launcher, a planted tool and temp directories;
// `parseDelay` slows the parse so a test can act *during* it.

import Combine
import XCTest
@testable import VideoScan

@MainActor
final class FamilySearchPullLifecycleTests: XCTestCase {

    private struct SilentLauncher: FamilySearchPullLauncher {
        func open(_ url: URL) {}
    }

    private var root: URL!
    private var toolURL: URL!
    private var gedcomDirectory: URL!
    private var staging: URL!
    private var outputURL: URL!
    private var notifications: [(title: String, body: String)] = []

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory
            .appendingPathComponent("fs-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        gedcomDirectory = root.appendingPathComponent("GEDCOM", isDirectory: true)
        staging = root.appendingPathComponent("staging", isDirectory: true)
        for dir in [bin, gedcomDirectory!, staging!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        toolURL = bin.appendingPathComponent("getmyancestors")
        try "#!/bin/sh\nexit 0\n".write(to: toolURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
        outputURL = staging.appendingPathComponent("familysearch-tree.ged")
        notifications = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    /// 30 ms polls: `pollsBeforeQuiet` (15) ≈ 450 ms of no growth.
    private static let pollInterval: Duration = .milliseconds(30)

    private func makeCenter(parseDelay: Duration = .zero) -> FamilySearchPullCenter {
        let toolURL = toolURL!, staging = staging!, outputURL = outputURL!
        return FamilySearchPullCenter(
            makeCoordinator: { directory in
                let coordinator = FamilySearchPullCoordinator(
                    gedcomDirectory: directory,
                    defaultUsername: "rick@example.com",
                    scriptURL: staging.appendingPathComponent("get-family-tree.command"),
                    locator: FamilySearchToolLocator(overridePath: toolURL.path),
                    launcher: SilentLauncher(),
                    pollInterval: Self.pollInterval,
                    parseDelay: parseDelay)
                coordinator.request.outputURL = outputURL
                return coordinator
            },
            notify: { [weak self] title, body in
                self?.notifications.append((title, body))
            })
    }

    private func gedcom(people: Int, trailer: Bool = true) -> String {
        var text = "0 HEAD\n"
        for i in 1...people {
            text += "0 @I\(i)@ INDI\n1 NAME Person\(i) /Breen/\n"
            if i > 1 { text += "1 FAMC @F1@\n" }
        }
        text += "0 @F1@ FAM\n1 HUSB @I1@\n"
        if trailer { text += "0 TRLR\n" }
        return text
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func wait(until predicate: @escaping () -> Bool,
                      timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func isReady(_ phase: FamilySearchPullCoordinator.Phase) -> Bool {
        if case .ready = phase { return true }
        return false
    }

    // MARK: Item 2 — the parse is owned

    func testForgetDuringParseNeverPublishesReady() async throws {
        let center = makeCenter(parseDelay: .milliseconds(300))
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        let file = staging.appendingPathComponent("handed-in.ged")
        try write(gedcom(people: 2), to: file)

        coordinator.installFromFile(file)
        guard case .parsing(let output) = coordinator.phase else {
            return XCTFail("expected .parsing, got \(coordinator.phase)")
        }
        XCTAssertEqual(output, file)
        XCTAssertEqual(center.status, .downloading(since: center.status.sinceOrNow),
                       "parsing is still 'working' to the rest of the app")

        center.forget()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(center.coordinator)

        // Long enough for the abandoned parse to have finished.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(coordinator.phase, .idle, "a forgotten parse must not publish .ready")
        XCTAssertEqual(center.status, .none)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testDismissIfSettledDuringParseLeavesItAliveAndItCompletes() async throws {
        let center = makeCenter(parseDelay: .milliseconds(300))
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        let file = staging.appendingPathComponent("handed-in.ged")
        try write(gedcom(people: 3), to: file)

        coordinator.installFromFile(file)
        guard case .parsing = coordinator.phase else {
            return XCTFail("expected .parsing, got \(coordinator.phase)")
        }

        // The sheet-close path. Before the `.parsing` phase existed the
        // coordinator was still `.idle` here and got dropped.
        center.dismissIfSettled()
        XCTAssertTrue(center.coordinator === coordinator)

        await wait { self.isReady(coordinator.phase) }
        guard case .ready(_, let new, _, _) = coordinator.phase else {
            return XCTFail("expected .ready, got \(coordinator.phase)")
        }
        XCTAssertEqual(new.people, 3)
        XCTAssertEqual(center.status, .readyToInstall)
        XCTAssertEqual(notifications.count, 1)
    }

    func testTwoRapidParsesOnlyTheLatestPublishes() async throws {
        let center = makeCenter(parseDelay: .milliseconds(200))
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        let first = staging.appendingPathComponent("first.ged")
        let second = staging.appendingPathComponent("second.ged")
        try write(gedcom(people: 2), to: first)
        try write(gedcom(people: 5), to: second)

        var readyPeopleCounts: [Int] = []
        let subscription = coordinator.$phase.sink { phase in
            if case .ready(_, let new, _, _) = phase { readyPeopleCounts.append(new.people) }
        }
        defer { subscription.cancel() }

        coordinator.installFromFile(first)
        coordinator.installFromFile(second)

        await wait { self.isReady(coordinator.phase) }
        // Give the superseded parse every chance to (wrongly) publish.
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(readyPeopleCounts, [5], "only the latest parse may publish, exactly once")
        XCTAssertEqual(notifications.count, 1)
        guard case .ready(let output, _, _, _) = coordinator.phase else {
            return XCTFail("expected .ready, got \(coordinator.phase)")
        }
        XCTAssertEqual(output, second)
    }

    func testKeepCurrentDuringParseDropsTheResult() async throws {
        // "Keep current" is coordinator.cancel() without the center's forget.
        let center = makeCenter(parseDelay: .milliseconds(300))
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        let file = staging.appendingPathComponent("handed-in.ged")
        try write(gedcom(people: 2), to: file)
        coordinator.installFromFile(file)
        coordinator.cancel()
        XCTAssertEqual(coordinator.phase, .idle)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Item 3 — a pause is not a failure

    func testAPauseLongerThanTheQuietThresholdKeepsWatchingAndFinishes() async throws {
        let center = makeCenter()
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        coordinator.launch()
        guard case .waiting = coordinator.phase else {
            return XCTFail("expected .waiting, got \(coordinator.phase)")
        }

        // The tool creates the file and writes some of it…
        try write(gedcom(people: 2, trailer: false), to: outputURL)
        try await Task.sleep(for: Self.pollInterval * 4)
        try append("0 @I3@ INDI\n1 NAME Third /Breen/\n", to: outputURL)

        // …then pauses well past pollsBeforeQuiet (15 × 30 ms = 450 ms).
        // The old stall detector would have FAILED the run here.
        let pause = Self.pollInterval * (FamilySearchPullCoordinator.pollsBeforeQuiet + 25)
        try await Task.sleep(for: pause)
        guard case .waiting = coordinator.phase else {
            return XCTFail("a pause must not fail the run; got \(coordinator.phase)")
        }
        XCTAssertNotNil(coordinator.quietSince, "the pause is surfaced as a soft note")
        XCTAssertEqual(center.status, .downloading(since: center.status.sinceOrNow))

        // Growth resumes → note clears.
        try append("0 @I4@ INDI\n1 NAME Fourth /Breen/\n", to: outputURL)
        await wait { coordinator.quietSince == nil }
        XCTAssertNil(coordinator.quietSince)

        // Trailer lands → ready.
        try append("0 TRLR\n", to: outputURL)
        await wait { self.isReady(coordinator.phase) }
        guard case .ready(_, let new, _, _) = coordinator.phase else {
            return XCTFail("expected .ready after the trailer, got \(coordinator.phase)")
        }
        XCTAssertEqual(new.people, 4)
        XCTAssertNil(coordinator.quietSince)
    }

    func testAFileThatWasSeenAndThenRemovedFails() async throws {
        let center = makeCenter()
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        coordinator.launch()

        try write(gedcom(people: 2, trailer: false), to: outputURL)
        try await Task.sleep(for: Self.pollInterval * 4)
        try FileManager.default.removeItem(at: outputURL)

        await wait { if case .failed = coordinator.phase { return true } else { return false } }
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("expected .failed after the file vanished, got \(coordinator.phase)")
        }
        XCTAssertTrue(message.contains("was removed"), message)
        XCTAssertEqual(center.status, .failed)
        XCTAssertNil(coordinator.quietSince)
    }

    func testAFileThatHasNotAppearedYetIsNotAFailure() async throws {
        // Missing before it was ever seen = "not ours yet", exactly as before.
        let center = makeCenter()
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        coordinator.launch()
        try await Task.sleep(for: Self.pollInterval * 30)
        guard case .waiting = coordinator.phase else {
            return XCTFail("expected .waiting, got \(coordinator.phase)")
        }
        XCTAssertNil(coordinator.quietSince)
    }

    func testForgetClearsTheQuietNote() async throws {
        let center = makeCenter()
        let coordinator = center.begin(gedcomDirectory: gedcomDirectory)
        coordinator.launch()
        try write(gedcom(people: 2, trailer: false), to: outputURL)
        await wait { coordinator.quietSince != nil }
        XCTAssertNotNil(coordinator.quietSince)
        center.forget()
        XCTAssertNil(coordinator.quietSince)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testQuietMessageWording() {
        let since = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            FamilySearchPullCoordinator.quietMessage(fileName: "tree.ged", since: since,
                                                     now: since.addingTimeInterval(30)),
            "No change to tree.ged for under a minute — Terminal may be waiting for you (password prompt, or a pause between pages). Still watching.")
        XCTAssertEqual(
            FamilySearchPullCoordinator.quietMessage(fileName: "tree.ged", since: since,
                                                     now: since.addingTimeInterval(4 * 60 + 5)),
            "No change to tree.ged for 4 min — Terminal may be waiting for you (password prompt, or a pause between pages). Still watching.")
        XCTAssertEqual(
            FamilySearchPullCoordinator.quietMessage(fileName: "tree.ged", since: since,
                                                     now: since.addingTimeInterval(61)),
            "No change to tree.ged for 1 min — Terminal may be waiting for you (password prompt, or a pause between pages). Still watching.")
    }
}

private extension FamilySearchPullCenter.Status {
    /// The `since` inside `.downloading`, or now — lets a test assert the
    /// case without caring about the exact timestamp.
    var sinceOrNow: Date {
        if case .downloading(let since) = self { return since }
        return Date()
    }
}
