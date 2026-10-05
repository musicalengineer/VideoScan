// MusicTriageOffMainTests.swift
// 2026-10-04 perf: the Catalog's music-library chip computed
// `MusicTriage.candidateIDs` INSIDE `CatalogContent.body` (through a render
// memo, so on the first render after every catalog change — 0.28 s in
// Rick's Release trace). It is now worked out in
// `.task(id: musicTriageKey)`: Sendable rows projected on the main actor,
// the SAME generic `candidateIDs` run off it.
//
//   Logic/Equivalence — the rows' answer equals the records' answer, order
//               kept (CatalogOffMainTotalsTests pins it on the full veto
//               matrix; here on the 100k catalog).
//   Scale     — 100k records: the old in-body pass timed beside the new
//               main-actor projection; both halves under explicit budgets.
//   Sensor    — the banner and body no longer call `MusicTriage.candidateIDs`;
//               the task does, in a detached task.
// Isolation: pure functions over constructed records.
// Media matrix: N/A — no media opened.
//
// Suites: MusicTriageOffMainTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Music triage chip off the main actor", .serialized)
@MainActor
struct MusicTriageOffMainTests {

    private func rec(_ name: String, _ stream: StreamType, dir: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.ext = (name as NSString).pathExtension.uppercased()
        r.streamTypeRaw = stream.rawValue
        r.directory = dir
        r.fullPath = dir + "/" + name
        r.sizeBytes = 8_000_000
        return r
    }

    /// 100k: 60% music library, the rest family video (whose stems protect
    /// a slice of the audio) and Avid MXF audio halves. Budgets (Release):
    /// main-actor projection under 150 ms, off-main detection under 1 s.
    @Test func hundredThousandRecordsUnderBudget() async {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let vol = "/Volumes/Drive\(i % 3)"
            switch i % 10 {
            case 0...5: records.append(rec("track\(i).\(i % 2 == 0 ? "mp3" : "m4a")", .audioOnly, dir: "\(vol)/iTunes/Music"))
            case 6: records.append(rec("home\(i).wav", .audioOnly, dir: "\(vol)/Family"))
            case 7: records.append(rec("home\(i - 1).mov", .videoAndAudio, dir: "\(vol)/Family"))
            case 8: records.append(rec("A01\(i).mxf", .audioOnly, dir: "\(vol)/Avid"))
            default: records.append(rec("clip\(i).mov", .videoOnly, dir: "\(vol)/Family"))
            }
        }
        let clock = ContinuousClock()
        var start = clock.now
        let reference = MusicTriage.candidateIDs(in: records)
        let oldInBody = clock.now - start

        start = clock.now
        let rows = CatalogStorageRow.project(records)
        let newMain = clock.now - start
        let (ids, offMain) = await Task.detached(priority: .utility) {
            let s = ContinuousClock.now
            let ids = MusicTriage.candidateIDs(in: rows)
            return (ids, ContinuousClock.now - s)
        }.value

        print("PERF_SCALE music chip: old in-body pass \(oldInBody); new main-actor projection \(newMain); off-main detection \(offMain)")
        #expect(ids == reference)
        #expect(ids.count == 60_000, "every library track and no .wav beside a same-stem video, no MXF half")
        #expect(newMain < PerformanceLane.debugCeiling(.milliseconds(150)), "projection took \(newMain)")
        #expect(offMain < .seconds(1), "detection took \(offMain)")
    }

    @Test func theBodyNoLongerComputesTheCandidates() throws {
        let src = try SourceTree.appSource(named: "CatalogHelpers.swift")
        let code = src.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        #expect(!code.contains("musicTriageMemo"), "the in-body memo is back")
        #expect(code.contains("@State private var musicTriageCandidateIDs: [UUID] = []"))
        #expect(code.contains(".task(id: musicTriageKey) { await refreshMusicTriageCandidates() }"))
        let refresh = try #require(code.range(of: "private func refreshMusicTriageCandidates() async {"))
        let body = String(code[refresh.upperBound...].prefix(600))
        let detached = try #require(body.range(of: "Task.detached(priority: .utility) {"))
        #expect(String(body[detached.upperBound...]).contains("MusicTriage.candidateIDs(in: rows)"), "the detection runs in the detached task")
        #expect(code.components(separatedBy: "MusicTriage.candidateIDs(").count == 2, "exactly one call — in the task")
    }
}
