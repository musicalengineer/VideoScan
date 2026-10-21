// PersonFinderLiveCatalogPrefilterUnitTests.swift
// The Person Finder live-catalog prefilter (2026-10-21 fix — see
// PersonFinderLiveCatalogPrefilterTests.swift for the bug and the sandbox
// cases). This file has no filesystem or global state, so the gauntlet can
// select it:
//   LOGIC   the value snapshot keeps every rule's input; no catalog → nil;
//           the always-written job-log line and the breakdown wording.
//   SCALE   100k synthetic records: snapshot + skip set within a budget.
//   SENSOR  the job path passes the live source through and never reads the
//           catalog store; ContentView wires it (source pins, comments
//           excluded).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func unitRecord(_ path: String, stream: StreamType = .videoAndAudio,
                        detected: [String] = [], junk: Int = 0,
                        duration: Double = 60, resolution: String = "1920x1080") -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.streamTypeRaw = stream.rawValue
    r.detectedPeople = detected
    r.junkScore = junk
    r.durationSeconds = duration
    r.resolution = resolution
    return r
}

@Suite("Person Finder live prefilter — logic")
@MainActor
struct PersonFinderLiveCatalogPrefilterLogicTests {

    @Test("no catalog connected → nil (the job says so), not an empty catalog")
    func noSourceIsNil() async {
        #expect(await pfLiveCatalogSkipResult(targetPersonName: "donna", source: nil) == nil)
        #expect(await pfLiveCatalogSkipResult(targetPersonName: "donna", source: { [] })
                == CatalogSkipResult())
        #expect(await PFLiveCatalogSource(nil).skipResult(targetPersonName: "donna") == nil)
        let one = PFLiveCatalogSource { [PFSkipFacts(fullPath: "/v/a.wav", isUnscannable: true)] }
        let result = await one.skipResult(targetPersonName: nil)
        #expect(result?.unscannable == ["/v/a.wav"])
        #expect(result?.checkedRecords == 1)
    }

    @Test("the value snapshot keeps every rule's input (records without a path dropped)")
    func snapshotFaithful() {
        let r = unitRecord("/v/a.mov", stream: .videoOnly, detected: ["Donna"], junk: 7,
                           duration: 3.5, resolution: "640x480")
        r.suspectedPeople = ["Hallie"]
        let unnamed = unitRecord("")
        let facts = pfSkipFacts(from: [r, unnamed])
        #expect(facts == [PFSkipFacts(fullPath: "/v/a.mov", isUnscannable: false,
                                      detectedPeople: ["Donna"], suspectedPeople: ["Hallie"],
                                      junkScore: 7, durationSeconds: 3.5, resolution: "640x480")])
        for stream in [StreamType.audioOnly, .noStreams, .ffprobeFailed] {
            #expect(PFSkipFacts(unitRecord("/v/x", stream: stream)).isUnscannable)
        }
        for stream in [StreamType.videoAndAudio, .videoOnly] {
            #expect(!PFSkipFacts(unitRecord("/v/x", stream: stream)).isUnscannable)
        }
    }

    @Test("the prefilter is never silent: one summary line for every state")
    func summaryLine() {
        #expect(pfPrefilterSummaryLine(connected: true, checked: 0, skipped: 0)
                == "Catalog prefilter: the catalog has no records loaded yet — nothing skipped")
        #expect(pfPrefilterSummaryLine(connected: true, checked: 14_210, skipped: 0)
                == "Catalog prefilter: checked 14210 catalog record(s), skipped 0 file(s)")
        #expect(pfPrefilterSummaryLine(connected: true, checked: 5, skipped: 2)
                == "Catalog prefilter: checked 5 catalog record(s), skipped 2 file(s)")
        #expect(pfPrefilterSummaryLine(connected: false, checked: 0, skipped: 0)
                == "Catalog prefilter: no catalog connected — nothing skipped")
    }

    @Test("the breakdown keeps the pre-fix wording and order")
    func breakdownWording() {
        var r = CatalogSkipResult()
        #expect(r.breakdownDetail(targetName: "Donna") == "")
        r.unscannable = ["a"]; r.alreadyKnown = ["b", "c"]; r.junkScored = ["d"]
        r.tooShort = ["e"]; r.lowResolution = ["f"]
        #expect(r.breakdownDetail(targetName: "Donna")
                == " (1 unscannable, 2 already-known for Donna, 1 junk-scored, 1 too-short, 1 low-resolution)")
    }
}

@Suite("Person Finder live prefilter — scale (100k records)")
@MainActor
struct PersonFinderLiveCatalogPrefilterScaleTests {

    @Test("SCALE: 100k synthetic records snapshot + skip set within budget")
    func hundredThousand() async throws {
        let n = 100_000
        var recs: [VideoRecord] = []
        recs.reserveCapacity(n)
        for i in 0..<n {
            switch i % 5 {
            case 0: recs.append(unitRecord("/Volumes/S/\(i).wav", stream: .audioOnly))
            case 1: recs.append(unitRecord("/Volumes/S/\(i).mov", detected: ["Donna"]))
            case 2: recs.append(unitRecord("/Volumes/S/\(i).mov", duration: 1))
            case 3: recs.append(unitRecord("/Volumes/S/\(i).mov", resolution: "320x240"))
            default: recs.append(unitRecord("/Volumes/S/\(i).mov"))
            }
        }
        // The snapshot closure is @Sendable; VideoRecord is not. In the app
        // the closure captures the (Sendable, main-actor) model instead; here
        // the array is only ever touched on the main actor.
        nonisolated(unsafe) let catalog = recs
        let start = ContinuousClock.now
        let result = try #require(await pfLiveCatalogSkipResult(
            targetPersonName: "donna", source: { pfSkipFacts(from: catalog) }))
        let elapsed = ContinuousClock.now - start
        #expect(result.checkedRecords == n)
        #expect(result.unscannable.count == n / 5)
        #expect(result.alreadyKnown.count == n / 5)
        #expect(result.tooShort.count == n / 5)
        #expect(result.lowResolution.count == n / 5)
        #expect(result.all.count == 4 * n / 5)
        // Budget: Debug build on the M4/M1 measures ~0.12 s; the old path
        // decoded ~80 MB of JSON on the main actor at every job start.
        #expect(elapsed < .seconds(5), "100k prefilter took \(elapsed)")
        print("PF live prefilter 100k: \(elapsed)")
    }
}

@Suite("Person Finder live prefilter — sensor (source wiring)")
struct PersonFinderLiveCatalogPrefilterSensor {

    /// Source text with whole-line comments removed, so a doc comment that
    /// names the old path cannot satisfy or trip a pin.
    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("SENSOR: the job path passes the live source to the prefilter and never reads the store; ContentView wires it")
    func wiring() throws {
        let lifecycle = try code("PersonFinderModel+JobLifecycle.swift")
        #expect(lifecycle.contains("let liveCatalog = PFLiveCatalogSource(self.catalogSkipFactsSource)"))
        #expect(lifecycle.contains("liveCatalog: liveCatalog"))
        #expect(lifecycle.contains("await liveCatalog.skipResult(targetPersonName: targetName)"))
        #expect(!lifecycle.contains("pfPersonScanSkipResult("))
        #expect(!lifecycle.contains("readRecordsWithoutAdopting"))
        #expect(!lifecycle.contains("CatalogStore"))
        let content = try code("ContentView.swift")
        #expect(content.contains("personFinderModel.catalogSkipFactsSource = { [weak catalogModel] in"))
        #expect(content.contains("catalogModel?.personScanSkipFacts() ?? []"))
    }
}
