import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// HallieShellCLITests, continued: the handleCommand characterization added
// 2026-10-29. An extension of the existing suite (same harness, same
// .serialized @MainActor suite) in its own file so HallieShellCLITests.swift
// stays under SwiftLint's 3,000-line limit.

extension HallieShellCLITests {

    // MARK: handleCommand — characterization (2026-10-29, before the split)
    //
    // Pins the colon-command branches no other test reached: unknown
    // command, :cancel with nothing pending, --no-actions on a citation and
    // on the photo, and the photo's no-photo / refused paths. Green on the
    // unchanged CCN 33 handleCommand, green after it was split.

    @Test func unknownCommandAndIdleCancelAnswerWithoutLeavingTheSession() async throws {
        let harness = Harness(inputs: [":frobnicate", ":cancel", ":quit"])
        let code = await HallieShellCLI.run(
            options: try HallieShellCLI.parse(arguments: ["--hallie"]), input: harness.nextInput,
            output: { harness.output.append($0) }, dependencies: harness.dependencies())
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.output.contains("Unknown command. Type :help."))
        #expect(harness.output.contains("No clarification is pending."))
        #expect(harness.output.last == "Goodbye.")
    }

    @Test func noActionsNamesTheCitationAndNeverTouchesMedia() async throws {
        let harness = Harness(
            inputs: ["Was Donna there?", ":play 1", ":reveal 1", ":open-photo", ":quit"],
            translations: [.presence(.init(people: ["Donna"]))])
        let answer = citedAnswer(path: "/isolated/available.mov")
        harness.executeTurn = { _, _ in answer }
        let code = await HallieShellCLI.run(
            options: try HallieShellCLI.parse(arguments: ["--hallie", "--no-actions"]), input: harness.nextInput,
            output: { harness.output.append($0) }, dependencies: harness.dependencies())
        #expect(code == HallieShellCLI.ExitCode.success.rawValue)
        #expect(harness.mediaActions.isEmpty)
        #expect(harness.output.filter { $0 == "\(HallieShellCLI.actionsDisabledNotice) (available.mov)" }.count == 2)
        // :open-photo checks the switch before it looks for a photo.
        #expect(harness.output.contains(HallieShellCLI.actionsDisabledNotice))
        #expect(!harness.output.contains("No biography photo is available for the last answer."))
    }

    @Test func photoCommandsWithNoPhotoInformThenFail() async throws {
        let harness = Harness(inputs: [":photo", ":reveal-photo", ":quit"])
        let code = await HallieShellCLI.run(
            options: try HallieShellCLI.parse(arguments: ["--hallie"]), input: harness.nextInput,
            output: { harness.output.append($0) }, dependencies: harness.dependencies())
        // :photo only informs; :reveal-photo with nothing to reveal ends the
        // session as a media failure (the :quit is never read).
        #expect(code == HallieShellCLI.ExitCode.mediaUnavailable.rawValue)
        #expect(harness.output.filter { $0 == "No biography photo is available for the last answer." }.count == 2)
        #expect(harness.mediaActions.isEmpty)
        #expect(!harness.output.contains("Goodbye."))
    }

    @Test func refusedPhotoActionNeverClaimsItOpened() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-photo-refused-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("portrait.png")
        try onePixelPNG.write(to: photo)
        var profile = POIProfile(name: "Alex River", referencePath: root.path)
        profile.coverImageFilename = photo.lastPathComponent
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alex /River/
        1 BIRT
        2 DATE 1 JAN 1900
        0 TRLR
        """)
        let harness = Harness(
            inputs: ["Tell me about Alex River", ":open-photo", ":quit"],
            profiles: [profile], graph: graph,
            translations: [.graph(.init(people: ["Alex River"], operation: .biography))])
        harness.mediaActionShouldSucceed = false
        let code = await HallieShellCLI.run(
            options: try HallieShellCLI.parse(arguments: ["--hallie"]), input: harness.nextInput,
            output: { harness.output.append($0) }, dependencies: harness.dependencies())
        #expect(code == HallieShellCLI.ExitCode.mediaUnavailable.rawValue)
        #expect(harness.mediaActions == [.play(photo)])
        #expect(harness.output.contains("The system refused the media action; nothing was opened."))
        #expect(!harness.output.contains("opening portrait.png"))
    }
}
