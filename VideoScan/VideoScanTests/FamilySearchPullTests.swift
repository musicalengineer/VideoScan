// FamilySearchPullTests.swift
// LOGIC + ISOLATION + SCALE + SENSOR for "Get Family Tree" (2026-08-25).
//
// The load-bearing test in this file is `noOptionCombinationEverEmitsAPasswordFlag`.
// The entire design rests on VideoScan never handling the user's FamilySearch
// password: getmyancestors POSTs credentials directly rather than using OAuth,
// and docs/familysearch_api_notes.md forbids VideoScan from collecting or
// proxying them. `-p`, `--save-settings`, and `--show-password` are the three
// flags that would break that, so the option space is swept exhaustively
// rather than spot-checked.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tool = URL(fileURLWithPath: "/tmp/venv/bin/getmyancestors")

private func request(
    username: String = "rick@example.com",
    ascend: Int = 8,
    descend: Int = 0,
    personID: String = "",
    marriage: Bool = true,
    rateLimit: Int = 2,
    concurrency: Int = 4,
    output: String = "/tmp/out.ged"
) -> FamilySearchPullRequest {
    FamilySearchPullRequest(
        username: username, ascend: ascend, descend: descend,
        startPersonID: personID, includeMarriage: marriage,
        rateLimit: rateLimit, concurrency: concurrency,
        outputURL: URL(fileURLWithPath: output))
}

// MARK: - SENSOR: the password can never reach the command line

@Test func noOptionCombinationEverEmitsAPasswordFlag() throws {
    // Production shape: every setting the sheet can produce, swept.
    for ascend in FamilySearchPullRequest.ascendRange {
        for descend in FamilySearchPullRequest.descendRange {
            for marriage in [true, false] {
                for personID in ["", "LF7T-Y4C"] {
                    let command = try FamilySearchPullCommand(
                        toolURL: tool,
                        request: request(ascend: ascend, descend: descend,
                                         personID: personID, marriage: marriage))
                    for forbidden in FamilySearchPullCommand.forbiddenArguments {
                        #expect(!command.arguments.contains(forbidden),
                                "emitted \(forbidden) for a=\(ascend) d=\(descend)")
                    }
                    // Nothing password-shaped anywhere in the rendered line.
                    let line = command.displayLine.lowercased()
                    #expect(!line.contains("password"))
                    #expect(!line.contains("--save-settings"))
                }
            }
        }
    }
}

@Test func generatedScriptNeverMentionsAStoredPassword() throws {
    let command = try FamilySearchPullCommand(toolURL: tool, request: request())
    let script = FamilySearchPullScript(
        command: command,
        scriptURL: URL(fileURLWithPath: "/tmp/get-family-tree.command"))
    let contents = script.contents

    #expect(!contents.contains("-p "))
    #expect(!contents.contains("--show-password"))
    #expect(!contents.contains("--save-settings"))
    // It must pause for the human before running anything.
    #expect(contents.contains("read -r"))
    #expect(contents.contains("Press Return to run"))
    // And it must say plainly whose password it is.
    #expect(contents.contains("never sent to VideoScan"))
}

// MARK: - LOGIC: command construction

@Test func ascendIsClampedToTheApiCeiling() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool, request: request(ascend: 20))
    let index = try #require(command.arguments.firstIndex(of: "-a"))
    #expect(command.arguments[index + 1] == "8")
}

@Test func ascendIsClampedUpFromZero() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool, request: request(ascend: 0))
    let index = try #require(command.arguments.firstIndex(of: "-a"))
    #expect(command.arguments[index + 1] == "1")
}

@Test func zeroDescendOmitsTheFlagEntirely() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool, request: request(descend: 0))
    #expect(!command.arguments.contains("-d"))
}

@Test func descendIsClampedToFour() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool, request: request(descend: 99))
    let index = try #require(command.arguments.firstIndex(of: "-d"))
    #expect(command.arguments[index + 1] == "4")
}

@Test func marriageFlagIsOptional() throws {
    let on = try FamilySearchPullCommand(toolURL: tool, request: request(marriage: true))
    let off = try FamilySearchPullCommand(toolURL: tool, request: request(marriage: false))
    #expect(on.arguments.contains("-m"))
    #expect(!off.arguments.contains("-m"))
}

@Test func personIDIsUppercasedAndPassed() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool, request: request(personID: "lf7t-y4c"))
    let index = try #require(command.arguments.firstIndex(of: "-i"))
    #expect(command.arguments[index + 1] == "LF7T-Y4C")
}

@Test func blankPersonIDMeansStartFromTheSignedInUser() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool, request: request(personID: "   "))
    #expect(!command.arguments.contains("-i"))
}

// MARK: - LOGIC: validation refuses bad input

@Test func emptyUsernameIsRejected() {
    #expect(throws: FamilySearchPullError.emptyUsername) {
        try FamilySearchPullCommand(toolURL: tool, request: request(username: "  "))
    }
}

@Test func usernameWithANewlineIsRejected() {
    // A newline would let a pasted value append a second shell line.
    #expect(throws: FamilySearchPullError.unsafeUsername) {
        try FamilySearchPullCommand(
            toolURL: tool, request: request(username: "rick@example.com\nrm -rf /"))
    }
}

@Test func malformedPersonIDsAreRejected() {
    for bad in ["LF7TY4C", "LF7T-Y4CX", "LF7-Y4C", "LF7T_Y4C", "L F7T-Y4C"] {
        #expect(throws: FamilySearchPullError.invalidPersonID(bad)) {
            try FamilySearchPullCommand(
                toolURL: tool, request: request(personID: bad))
        }
    }
}

@Test func outputMustBeAGedcomPath() {
    let bad = request(output: "/tmp/tree.txt")
    #expect(throws: FamilySearchPullError.outputNotGedcom(bad.outputURL)) {
        try FamilySearchPullCommand(toolURL: tool, request: bad)
    }
}

// MARK: - LOGIC: shell quoting

@Test func pathsWithSpacesAreQuoted() throws {
    let command = try FamilySearchPullCommand(
        toolURL: tool,
        request: request(output: "/Users/rickb/My Trees/breen tree.ged"))
    #expect(command.displayLine.contains("'/Users/rickb/My Trees/breen tree.ged'"))
}

@Test func embeddedSingleQuotesAreEscapedNotDropped() {
    let quoted = FamilySearchPullCommand.quoted("O'Connor's tree")
    #expect(quoted == #"'O'\''Connor'\''s tree'"#)
}

@Test func ordinaryValuesAreLeftUnquotedForReadability() {
    #expect(FamilySearchPullCommand.quoted("rick@example.com") == "rick@example.com")
    #expect(FamilySearchPullCommand.quoted("/tmp/out.ged") == "/tmp/out.ged")
}

// MARK: - ISOLATION: the locator only consults known paths

@Test func locatorReturnsNilWhenNothingIsInstalled() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let locator = FamilySearchToolLocator(
        overridePath: directory.appendingPathComponent("getmyancestors").path)
    #expect(locator.locate() == nil)
}

@Test func locatorRejectsANonExecutableFileOfTheRightName() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let planted = directory.appendingPathComponent("getmyancestors")
    try "not a program".write(to: planted, atomically: true, encoding: .utf8)

    let locator = FamilySearchToolLocator(overridePath: planted.path)
    #expect(locator.locate() == nil)
}

@Test func locatorRejectsADirectoryOfTheRightName() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    let planted = directory.appendingPathComponent("getmyancestors")
    try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let locator = FamilySearchToolLocator(overridePath: planted.path)
    #expect(locator.locate() == nil)
}

// MARK: - ISOLATION: a stale export is never adopted

@Test func aFileOlderThanTheLaunchIsIgnored() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stale = directory.appendingPathComponent("familysearch-tree.ged")
    try "0 HEAD".write(to: stale, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: stale.path)

    // Last week's export must not be mistaken for the one we just asked for.
    let size = await FamilySearchPullCoordinator.fileSize(at: stale, newerThan: Date())
    #expect(size == nil)
}

@Test func aFreshFileIsReported() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fresh = directory.appendingPathComponent("familysearch-tree.ged")
    let launch = Date()
    try String(repeating: "x", count: 128).write(
        to: fresh, atomically: true, encoding: .utf8)

    let size = await FamilySearchPullCoordinator.fileSize(at: fresh, newerThan: launch)
    #expect(size == 128)
}

@Test func aMissingFileReportsNoSize() async {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).ged")
    let size = await FamilySearchPullCoordinator.fileSize(
        at: missing, newerThan: .distantPast)
    #expect(size == nil)
}

// MARK: - LOGIC: script file is written safely

@Test func scriptIsWrittenOwnerOnlyExecutable() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scriptURL = directory.appendingPathComponent("get-family-tree.command")

    let command = try FamilySearchPullCommand(toolURL: tool, request: request())
    try FamilySearchPullScript(command: command, scriptURL: scriptURL).write()

    let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    // 0o700: nobody else on the machine can read or run it.
    #expect(permissions.int16Value == 0o700)
}

@Test func rewritingTheScriptReplacesTheOldCommand() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scriptURL = directory.appendingPathComponent("get-family-tree.command")

    try FamilySearchPullScript(
        command: try FamilySearchPullCommand(toolURL: tool, request: request(ascend: 3)),
        scriptURL: scriptURL).write()
    try FamilySearchPullScript(
        command: try FamilySearchPullCommand(toolURL: tool, request: request(ascend: 7)),
        scriptURL: scriptURL).write()

    let contents = try String(contentsOf: scriptURL, encoding: .utf8)
    #expect(contents.contains("-a 7"))
    #expect(!contents.contains("-a 3"))
}

// MARK: - LOGIC: completion is detected by the GEDCOM trailer

private func writeTemp(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("familysearch-tree.ged")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func aCompleteExportIsRecognisedByItsTrailer() async throws {
    let url = try writeTemp("0 HEAD\n0 @I1@ INDI\n1 NAME Rick /Breen/\n0 TRLR\n")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(await FamilySearchPullCoordinator.hasGedcomTrailer(at: url))
}

@Test func aTruncatedExportHasNoTrailer() async throws {
    // The failure that matters: the run died partway and left a file that
    // still parses. Without the trailer check we would install half a tree.
    let url = try writeTemp("0 HEAD\n0 @I1@ INDI\n1 NAME Rick /Bre")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(await !FamilySearchPullCoordinator.hasGedcomTrailer(at: url))
}

@Test func anEmptyFileHasNoTrailer() async throws {
    let url = try writeTemp("")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(await !FamilySearchPullCoordinator.hasGedcomTrailer(at: url))
}

@Test func aTrailerThatIsNotTheLastLineDoesNotCount() async throws {
    let url = try writeTemp("0 HEAD\n0 TRLR\n0 @I9@ INDI\n1 NAME Later /Person/\n")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(await !FamilySearchPullCoordinator.hasGedcomTrailer(at: url))
}

@Test func aMissingFileHasNoTrailer() async {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).ged")
    #expect(await !FamilySearchPullCoordinator.hasGedcomTrailer(at: missing))
}

@Test func trailerDetectionReadsOnlyTheTail() async throws {
    // A big export must not be slurped into memory to answer this.
    let filler = String(repeating: "1 NOTE padding padding padding\n", count: 200_000)
    let url = try writeTemp("0 HEAD\n" + filler + "0 TRLR\n")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let started = ContinuousClock.now
    let found = await FamilySearchPullCoordinator.hasGedcomTrailer(at: url)
    let elapsed = ContinuousClock.now - started

    #expect(found)
    #expect(elapsed < .milliseconds(250), "tail read took \(elapsed)")
}

// MARK: - SENSOR: the generated script is valid zsh

@Test func generatedScriptPassesZshSyntaxCheck() throws {
    // Regression sensor. The first draft assigned `status=$?`, which is a
    // read-only variable in zsh: the script aborted before the tool ran,
    // and no amount of string-matching would have caught it. Parse the
    // real thing with the real shell.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let scriptURL = directory.appendingPathComponent("get-family-tree.command")

    let command = try FamilySearchPullCommand(
        toolURL: tool,
        request: request(output: "/Users/rickb/My Trees/breen tree.ged"))
    try FamilySearchPullScript(command: command, scriptURL: scriptURL).write()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-n", scriptURL.path]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    process.waitUntilExit()

    let message = String(
        data: errors.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "zsh -n rejected the script: \(message)")
}

@Test func generatedScriptAvoidsZshReadOnlyNames() throws {
    // The specific trap, pinned by name so a future edit doesn't quietly
    // reintroduce it in a form `zsh -n` accepts but the shell rejects at
    // runtime (assigning a read-only variable is a runtime error).
    let command = try FamilySearchPullCommand(toolURL: tool, request: request())
    let contents = FamilySearchPullScript(
        command: command,
        scriptURL: URL(fileURLWithPath: "/tmp/x.command")).contents
    // Match assignments at the start of a line — `exit_status=` merely
    // *contains* `status=` and is the correct fix, not the bug.
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    for readOnly in ["status", "UID", "EUID", "PPID"] {
        let assigns = lines.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(readOnly)=")
        }
        #expect(!assigns, "assigns zsh read-only variable \(readOnly)")
    }
    #expect(contents.contains("exit_status=$?"))
}

// MARK: - LOGIC: reported depth

@Test func depthCountsTheLongestAncestorChain() {
    // Rick → father → grandfather: three generations.
    let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Richard /Breen/
    1 FAMC @F2@
    0 @I3@ INDI
    1 NAME George /Breen/
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I3@
    1 CHIL @I2@
    """)
    #expect(FamilySearchPullCoordinator.deepestAncestorDepth(in: graph) == 3)
}

@Test func depthOfALoneIndividualIsOne() {
    let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    """)
    #expect(FamilySearchPullCoordinator.deepestAncestorDepth(in: graph) == 1)
}

@Test func aCyclicPedigreeTerminatesInsteadOfRecursingForever() {
    // User-submitted trees really do contain these: I1 is recorded as his
    // own grandfather. The walk must stop, not blow the stack.
    let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Loop /One/
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Loop /Two/
    1 FAMC @F2@
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I1@
    1 CHIL @I2@
    """)
    let depth = FamilySearchPullCoordinator.deepestAncestorDepth(in: graph)
    #expect(depth >= 1)
    #expect(depth <= graph.people.count + 1)
}

// MARK: - SCALE: a deep tree is measured, not walked forever

@Test func depthOnADeepChainStaysWithinBudget() {
    // 20,000-generation chain — far past anything FamilySearch holds, and
    // the shape that would expose an accidental O(n²) walk or a stack
    // overflow from unmemoized recursion.
    let depth = 20_000
    var lines = ["0 HEAD"]
    lines.reserveCapacity(depth * 6)
    for i in 1...depth {
        lines.append("0 @I\(i)@ INDI")
        lines.append("1 NAME Person /Number\(i)/")
        if i < depth { lines.append("1 FAMC @F\(i)@") }
    }
    for i in 1..<depth {
        lines.append("0 @F\(i)@ FAM")
        lines.append("1 HUSB @I\(i + 1)@")
        lines.append("1 CHIL @I\(i)@")
    }
    let graph = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
    #expect(graph.people.count == depth)

    let started = ContinuousClock.now
    let measured = FamilySearchPullCoordinator.deepestAncestorDepth(in: graph)
    let elapsed = ContinuousClock.now - started

    #expect(measured == depth)
    // Memoized, this is linear. Generous budget so the test is about the
    // algorithm's shape, not the machine it runs on.
    #expect(elapsed < .seconds(5), "depth walk took \(elapsed)")
}

@Test func commandBuildingIsCheapEnoughToRunOnEveryKeystroke() throws {
    // refreshPreview() runs on every character typed into the sheet.
    let started = ContinuousClock.now
    for _ in 0..<10_000 {
        _ = try FamilySearchPullCommand(toolURL: tool, request: request()).displayLine
    }
    let elapsed = ContinuousClock.now - started
    #expect(elapsed < .seconds(2), "10k command builds took \(elapsed)")
}
