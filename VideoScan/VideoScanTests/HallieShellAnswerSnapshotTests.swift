// HallieShellAnswerSnapshotTests.swift
// GH #281 R3 (2026-10-06): characterization snapshots for
// HallieShellCLI.answer (the shell's per-turn router), recorded from the
// pre-refactor code (main@ebcd2f09) before the function was split.
//
// Scripted sessions run through HallieShellCLI.run with the standard test
// Harness (no model, no real files). Each session's console output, the
// transcript events (minus timestamps / ids), the questions that reached the
// translator and the media actions are snapshotted. The script visits the
// split-conjunction loop, the natural reset, the pronunciation lane, a
// telling session, a which-one clarification (narrowed, unmatched,
// selected, abandoned), an offer declined, the persona and small-talk local
// answers, the translator lane (archive AST, presence and record scopes,
// play-after-answer), a missing translation and a translator failure — once
// with --diagnostics and once without.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Shell answer: characterization snapshots", .serialized)
struct HallieShellAnswerSnapshotTests {
    typealias Harness = HallieShellCLITests.Harness

    static let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME William Love /Latta Sr./
    1 BIRT
    2 DATE 3 FEB 1875
    2 PLAC Wilmington, North Carolina
    0 @I2@ INDI
    1 NAME Donna /Breen/
    1 SEX F
    1 BIRT
    2 DATE 1959
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1958
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Tim /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1999
    1 FAMC @F1@
    0 @F1@ FAM
    1 HUSB @I3@
    1 WIFE @I2@
    1 CHIL @I4@
    0 TRLR
    """)

    static func record(_ path: String, people: [String]) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        value.confirmedByUserPeople = people.map {
            ConfirmedTag(name: $0, confirmedAt: Date(timeIntervalSince1970: 1))
        }
        return value
    }

    static var profiles: [POIProfile] {
        [
            POIProfile(name: "Tim Breen", referencePath: "/isolated/tim-a", aliases: ["Timmy"],
                       birthdate: Date(timeIntervalSince1970: 0)),
            POIProfile(name: "Timothy Breen", referencePath: "/isolated/tim-z", aliases: ["Timmy"],
                       birthdate: Date(timeIntervalSince1970: 946_684_800)),
            POIProfile(name: "Donna Breen", referencePath: "/isolated/donna", aliases: ["Donna"],
                       birthdate: Date(timeIntervalSince1970: -326_000_000)),
        ]
    }

    static let script = [
        "who was Donna Breen and do we have any videos of her",
        "start over",
        "how do you say Latta",
        "let me tell you about my dad",
        "he loved fishing on the lake",
        "that's all",
        "How old was Timmy in 2020?",
        "the one born in 1970",
        "the one from Paris",
        "2",
        "How old was Timmy in 2020?",
        "what's the weather like today",
        "hello hallie",
        "where were you born, hallie?",
        "It's pouring rain here today.",
        "show me videos of Donna",
        "who else is in it",
        "play donna at christmas",
        "research william love latter",
        "no",
        "tell me about Donna Breen",
        "how old was Donna in this video",
        "and what about Rick",
        "Invent something new",
        ":quit",
    ]

    static var translations: [ArchivistQueryAST] {
        [
            .graph(.init(people: ["Donna Breen"], operation: .biography)),
            .presence(.init(people: ["Donna"])),
            .temporal(.init(subject: "Timmy", operation: .age, reference: .explicitYear(2020))),
            .temporal(.init(subject: "Timmy", operation: .age, reference: .explicitYear(2020))),
            .presence(.init(people: ["Donna"])),
            .presence(.init(people: ["Donna"])),
            .graph(.init(people: ["william love latter"], operation: .biography)),
            .graph(.init(people: ["Donna Breen"], operation: .biography)),
            .temporal(.init(subject: "Donna", operation: .age, reference: .currentSelection)),
            .graph(.init(people: ["Rick Breen"], operation: .biography)),
        ]
    }

    static func render(_ harness: Harness, code: Int32) -> String {
        var lines = ["exit=\(code)", "translated=\(harness.translatedQuestions)",
                     "media=\(harness.mediaActions.map { String(reflecting: $0) })", "── output"]
        lines += harness.output
        lines.append("── transcript")
        for event in harness.transcriptEvents {
            lines.append("[\(event.sequence)] \(event.kind) route=\(event.route ?? "-") outcome=\(event.outcome ?? "-") "
                + "responder=\(event.responder ?? "-") mode=\(event.mode ?? "-") composedBy=\(event.composedBy ?? "-")")
            lines.append("    text=\(event.text)")
            lines.append("    query=\(event.queryDescription ?? "-") basis=\(event.basisLine ?? "-")")
            lines.append("    offers=\(event.offeredActions) media=\(event.mediaEvidence.map(\.filename))")
        }
        return HallieGoldenSnapshot.masked(lines.joined(separator: "\n"))
    }

    func session(_ arguments: [String], inputs: [String],
                 translations: [ArchivistQueryAST], failing: Bool = false) async throws -> String {
        let harness = Harness(
            inputs: inputs,
            records: [
                Self.record("/isolated/Donna/Christmas 1994.mov", people: ["Donna Breen"]),
                Self.record("/isolated/Donna/Cape 1996.mov", people: ["Donna Breen", "Tim Breen"]),
            ],
            profiles: Self.profiles, graph: Self.graph, translations: translations)
        harness.speakers = .init(ownerName: "Rick Breen", archivistName: "Hallie Mae")
        harness.executeRequest = { request, context in
            try await HallieTurnExecutor.execute(request, context: context)
        }
        if failing { harness.translationError = CocoaError(.featureUnsupported) }
        let options = try HallieShellCLI.parse(arguments: arguments)
        let code = await HallieShellCLI.run(
            options: options, input: harness.nextInput,
            output: { harness.output.append($0) },
            dependencies: harness.dependencies())
        return Self.render(harness, code: code)
    }

    @Test func scriptedSessionsMatchTheirRecordedSnapshots() async throws {
        var out: [String: String] = [:]
        out["1 diagnostics"] = try await session(
            ["--hallie", "--diagnostics", "--catalog", "/isolated/catalog.json"],
            inputs: Self.script, translations: Self.translations)
        out["2 plain"] = try await session(
            ["--hallie", "--catalog", "/isolated/catalog.json"],
            inputs: Self.script, translations: Self.translations)
        out["3 translator failure"] = try await session(
            ["--hallie", "--diagnostics"],
            inputs: ["Invent something", "hello hallie", "show me videos of Donna", ":quit"],
            translations: [], failing: true)
        out["4 once"] = try await session(
            ["--hallie", "--once", "who was Donna Breen and how old was Tim in 2020"],
            inputs: [], translations: Self.translations)
        // A which-one in --once mode: pins the turn's outcome (exit code),
        // which an interactive session never shows.
        out["5 once clarification"] = try await session(
            ["--hallie", "--catalog", "/isolated/catalog.json", "--once", "How old was Timmy in 2020?"],
            inputs: [], translations: [
                .temporal(.init(subject: "Timmy", operation: .age, reference: .explicitYear(2020))),
            ])
        try HallieGoldenSnapshot.verify("shell_answer", out)
    }
}
