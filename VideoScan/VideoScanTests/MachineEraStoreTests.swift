// MachineEraStoreTests.swift — the era job's observations as the app shows
// them (MachineEraStore.swift, InspectorMachineEraLine, the Catalog Status
// convergence line, the search index's observation layer; background step 1,
// item 8). Core's MachineEraResolverTests own the rules (close enough, the
// words, the bulk read at 100k).
//
// Dimensions (CLAUDE.md rule 8):
//   TRUTH      journal lines → the launch pass commits them → the applier's
//              hook refreshes the store → the inspector line reads
//              "Machine era: 1991–1995 · 8B, unconfirmed" and its help
//              carries the `by` (read back from catalog.sqlite, not from the
//              journal); without a row the line is absent, Status has no
//              line and search finds nothing by era.
//   LOGIC      Rick's date not close enough → "— disagrees with your date";
//              Rick's date edit re-counts the convergence (debounced, via
//              .videoScanCatalogMutated); the Status line sits beside the
//              journal line and is absent at M = 0 / nil.
//   SEARCH     "1990s", "90s", "early 90s" (typed and quoted) find the era
//              record; "1991-1995", "era.fused", "fused", "machine" and the
//              digest do not — and the index's held text carries none of
//              them; the fast path and the linear matcher agree with the
//              reference (canonical matcher OR the observation terms).
//   ISOLATION  terms for a path not in the catalog are inert; a failed read
//              keeps the old cache and says so once; `remove` drops a path's
//              words; `rebuild` keeps the layer; a stale refresh never
//              overwrites a newer one.
//   SCALE      100k records (50k with an era): the main-actor join + the
//              index layer + a "1990s" query inside the budget.
//   SENSOR     the store holds no SQL and never writes; no `extension
//              VideoScanModel` in it; the view body does a lookup only.
//   MEDIA      N/A — no media is opened. WRITER quartet: N/A (a reader; the
//              writer is JournalApplier, whose quartet stands).
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let machineBy = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"

@MainActor
private func journal(_ scene: CutoverScene) -> ObservationJournal {
    ObservationJournal(directory: scene.folder.appendingPathComponent("background/journal", isDirectory: true))
}

/// What EraJob writes for one file: one window, one fused line.
private func eraLines(_ digest: String, fused: String = "1991-1995") throws -> [ObservationLine] {
    [
        try ObservationLine(subjectID: digest, field: "era.yearRange", value: "1990-1996", by: machineBy, at: 1_762_000_000, confidence: 0.6,
                            evidence: ["frameTimesS": [3.75, 11.25, 18.75], "window": [0.0, 60.0], "rationale": "synthetic"], job: "TEST", unit: 0),
        try ObservationLine(subjectID: digest, field: "era.fused", value: fused, by: machineBy, at: 1_762_000_000, confidence: 0.6,
                            evidence: ["validEraWindows": 1, "windows": [[0.0, 60.0]], "burnedInYears": [Int]()], job: "TEST", unit: 0),
    ]
}

@MainActor
private func launched(_ label: String, lines: (String) throws -> [ObservationLine]) async throws -> (CutoverScene, VideoRecord, VideoRecord) {
    let scene = try CutoverScene.make(label)
    try await scene.importCatalog()
    let preview = try await scene.sqliteLoad()
    let healthyID = PoisonedCatalogFixture.id(.healthy)
    let healthy = try #require(preview.records.first { $0.id.uuidString == healthyID }.flatMap(CatalogCommit.digest(of:)))
    let written = try lines(healthy)
    if !written.isEmpty { try journal(scene).append(written) }
    try scene.writeLatch()
    scene.model.records = scene.model.loadCatalogAtLaunch()
    _ = try #require(await scene.model.journalApplier.launchPass?.value)
    // The applier's onApplied hook (or attach's own first refresh) scheduled one; await it.
    await scene.model.machineEras.pendingRefresh?.value
    let record = try scene.record(.healthy)
    let other = try #require(scene.model.records.first { $0.id.uuidString != healthyID && CatalogCommit.digest(of: $0) != nil
                                                          && CatalogCommit.digest(of: $0) != healthy })
    return (scene, record, other)
}

@MainActor
private func close(_ model: VideoScanModel) async {
    model.journalApplier.detach()
    model.machineEras.detach()
    if let c = model.catalogCutover.committer { await c.repository.close() }
}

private func ids(_ records: [VideoRecord]) -> Set<UUID> { Set(records.map(\.id)) }

/// Poll (50 ms) until `condition` holds; fail after `limit`.
@MainActor
private func waitUntil(_ limit: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("timed out waiting"); return }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@Suite("MachineEraStore — the era job's observations in the inspector, Status and search", .serialized)
@MainActor
struct MachineEraStoreTruthTests {

    @Test("TRUTH: a fused era committed by the applier is the inspector's line, with the by in its help, and the Status count once Rick dates it")
    func theCommittedEraIsTheInspectorLine() async throws {
        let (scene, healthy, other) = try await launched("era_truth") { try eraLines($0) }
        defer { scene.cleanup() }
        let model = scene.model
        #expect(model.machineEras.refreshCount >= 1)
        let shown = try #require(model.machineEras.shown(for: healthy))
        #expect(shown.text == "Machine era: 1991–1995 · 8B, unconfirmed")
        #expect(shown.help.contains(machineBy))
        #expect(shown.help.contains("Windows: 1 (0 s–1:00)"))
        #expect(shown.help.contains("Frames: 3 at 4 s, 11 s, 19 s"))
        #expect(model.machineEras.shown(for: other) == nil)
        // The cache came from catalog.sqlite: the row is there, through the store's read.
        let repository = try #require(model.catalogCutover.committer?.repository)
        let digest = try #require(CatalogCommit.digest(of: healthy))
        let stored = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: digest) }
        #expect(stored.contains { $0.field == "era.fused" && $0.value == "1991-1995" && $0.by == machineBy })
        // No confirmed date yet → no Status line.
        #expect(model.machineEras.convergence == nil)
        // Rick dates it 1993 → re-counted through the catalog-edit hook (debounced).
        healthy.userDate = "1993"
        healthy.userDateConfidence = UserDateConfidence.known.rawValue
        let before = model.machineEras.refreshCount
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        try await waitUntil { model.machineEras.refreshCount > before }
        #expect(model.machineEras.convergence == MachineEraConvergence(total: 1, agree: 1))
        #expect(model.machineEras.shown(for: healthy)?.text == "Machine era: 1991–1995 · 8B, unconfirmed")
        // A 1965 date (the re-recorded film case) is not close enough: said in words.
        healthy.userDate = "1965"
        await model.machineEras.refresh()
        #expect(model.machineEras.convergence == MachineEraConvergence(total: 1, agree: 0))
        #expect(model.machineEras.shown(for: healthy)?.text == "Machine era: 1991–1995 · 8B, unconfirmed — disagrees with your date")
        await close(model)
    }

    @Test("HOOK: an applier pass that commits a row refreshes the store; a pass of duplicates does not")
    func theApplierCommitRefreshesTheStore() async throws {
        let (scene, healthy, _) = try await launched("era_hook") { _ in [] }
        defer { scene.cleanup() }
        let model = scene.model
        #expect(model.machineEras.shown(for: healthy) == nil)
        let digest = try #require(CatalogCommit.digest(of: healthy))
        let lines = try eraLines(digest, fused: "1975-1985")
        try journal(scene).append(lines)
        let before = model.machineEras.refreshCount
        let pass = await model.journalApplier.applyPending()
        #expect(pass.applied == 2)
        try await waitUntil { model.machineEras.refreshCount > before }
        #expect(model.machineEras.shown(for: healthy)?.text == "Machine era: 1975–1985 · 8B, unconfirmed")
        // The same lines again (a lost cursor): duplicates only → no refresh scheduled.
        try journal(scene).markApplied(try #require(journal(scene).dayFiles().first), offset: 0)
        let settled = model.machineEras.refreshCount
        let again = await model.journalApplier.applyPending()
        #expect(again.applied == 0 && again.duplicates == 2)
        try await Task.sleep(for: MachineEraStore.debounce + .milliseconds(500))
        #expect(model.machineEras.refreshCount == settled)
        await close(model)
    }

    @Test("TRUTH: without a row the line is absent, Status has no line and no era word finds anything")
    func noRowNoLine() async throws {
        let (scene, healthy, _) = try await launched("era_none") { _ in [] }
        defer { scene.cleanup() }
        let model = scene.model
        #expect(model.machineEras.refreshCount >= 1)
        #expect(model.machineEras.eras.isEmpty)
        #expect(model.machineEras.shown(for: healthy) == nil)
        #expect(model.machineEras.convergence == nil)
        #expect(model.searchIndex.observationTerms(forPath: healthy.fullPath) == nil)
        await close(model)
    }

    @Test("SEARCH: 1990s, 90s and early 90s find the era record; the technical form neither finds it nor is held by the index")
    func theEraIsSearchableInHumanWordsOnly() async throws {
        let (scene, healthy, other) = try await launched("era_search") { try eraLines($0) }
        defer { scene.cleanup() }
        let model = scene.model
        let records = model.records
        for query in ["1990s", "90s", "early 90s", "\"early 90s\"", "Early 90s", "year:1993", "decade:1990"] {
            #expect(ids(model.searchIndex.filter(records: records, query: query)).contains(healthy.id), "\(query) finds it")
            #expect(model.searchIndex.count(records: records, query: query) >= 1)
        }
        let digest = try #require(CatalogCommit.digest(of: healthy))
        for query in ["1991-1995", "era.fused", "fused", "machine", "qwen3", digest, "late 90s", "1980s"] {
            #expect(!ids(model.searchIndex.filter(records: records, query: query)).contains(healthy.id), "\(query) must not find it")
        }
        let held = try #require(model.searchIndex.observationTerms(forPath: healthy.fullPath))
        #expect(held.text == "1990s\n90s\nearly 90s\nearly 1990s")
        for forbidden in ["1991", "1995", "era.", "fused", "machine", "qwen", digest] { #expect(!held.text.contains(forbidden)) }
        #expect(model.searchIndex.observationTerms(forPath: other.fullPath) == nil)
        await close(model)
    }
}

@Suite("MachineEraStore — logic, isolation, Status words")
@MainActor
struct MachineEraStoreLogicTests {

    static func record(_ n: Int, path: String? = nil, userDate: String? = nil, transcript: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path ?? "/Volumes/Synthetic/clip_\(n).mov"
        r.filename = (r.fullPath as NSString).lastPathComponent
        r.sizeBytes = 1_000 + Int64(n)
        r.contentFixity = ContentFixity(digest: String(format: "%064x", n), byteCount: r.sizeBytes,
                                        stamp: FileIdentityStamp(device: 1, inode: UInt64(n), size: r.sizeBytes, mtimeNs: 0))
        r.audioTranscript = transcript
        if let userDate { r.userDate = userDate; r.userDateConfidence = UserDateConfidence.known.rawValue }
        return r
    }

    nonisolated static func era(_ lo: Int, _ hi: Int, seq: Int64 = 1) -> MachineEra { MachineEra(lo: lo, hi: hi, by: machineBy, at: 0, seq: seq) }
    nonisolated static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    @Test func theStatusLineSitsBesideTheJournalLineAndIsAbsentAtZero() {
        let integrity = IntegrityReportFacts()
        let both = CatalogRealityFactsBuilder.information(integrity, backgroundJournal: JournalApplier.Counts(waiting: 2, refused: 0),
                                                         machineEra: MachineEraConvergence(total: 4, agree: 3))
        #expect(both.suffix(2) == ["Background: 2 journal lines waiting · 0 refused",
                                   "Machine era agrees with your confirmed date within 5 y: 3 of 4 (75 %)"])
        #expect(!CatalogRealityFactsBuilder.information(integrity, machineEra: nil).contains { $0.hasPrefix("Machine era") })
        #expect(!CatalogRealityFactsBuilder.information(integrity, machineEra: MachineEraConvergence(total: 0, agree: 0))
            .contains { $0.hasPrefix("Machine era") })
    }

    @Test func theStoreCountsOnlyContentsWithBothAndPublishesToStatusAndSearch() async {
        let store = MachineEraStore()
        let recs = [Self.record(1, userDate: "1993"), Self.record(2, userDate: "1965"), Self.record(3), Self.record(4, userDate: "1990"),
                    Self.record(1, path: "/Volumes/Copy/clip_1.mov", userDate: "1993")]          // a second copy of content 1
        let eras = [Self.hex(1): [Self.era(1991, 1995)], Self.hex(2): [Self.era(1975, 1985)], Self.hex(3): [Self.era(1997, 1999)]]
        var heard: [MachineEraConvergence?] = []
        var terms: [String: CatalogSearchIndex.ObservationTerms] = [:]
        store.onConvergence = { heard.append($0) }
        store.onSearchTerms = { terms = $0.byPath }
        store.attach(load: { eras }, records: { recs })
        #expect(await store.refresh())
        #expect(store.convergence == MachineEraConvergence(total: 2, agree: 1))       // per content: the copy is not counted twice
        #expect(heard.last == MachineEraConvergence(total: 2, agree: 1))
        #expect(Set(terms.keys) == ["/Volumes/Synthetic/clip_1.mov", "/Volumes/Copy/clip_1.mov",
                                    "/Volumes/Synthetic/clip_2.mov", "/Volumes/Synthetic/clip_3.mov"])
        #expect(terms["/Volumes/Synthetic/clip_3.mov"]?.text == "1990s\n90s\nlate 90s\nlate 1990s")
        #expect(store.shown(for: recs[1])?.text.hasSuffix("— disagrees with your date") == true)
        #expect(store.shown(for: recs[3]) == nil)
        store.detach()
    }

    @Test func aBestGuessDateCountsAndABadOneDoesNot() async {
        let store = MachineEraStore()
        let guess = Self.record(1, userDate: "1993-06")
        guess.userDateConfidence = UserDateConfidence.estimated.rawValue      // Rick's best guess is still Rick's date
        let junk = Self.record(2)
        junk.userDate = "sometime"                                              // malformed: not a confirmed date
        store.attach(load: { [Self.hex(1): [Self.era(1991, 1995)], Self.hex(2): [Self.era(1991, 1995)]] }, records: { [guess, junk] })
        await store.refresh()
        #expect(store.convergence == MachineEraConvergence(total: 1, agree: 1))
        store.detach()
    }

    @Test func aFailedReadKeepsTheOldCacheAndSaysSoOnce() async {
        let store = MachineEraStore()
        let failing = FailSwitch()
        var notes: [String] = []
        store.note = { notes.append($0) }
        let recs = [Self.record(1)]
        store.attach(load: {
            if failing.on { throw CutoverFailure(words: "disk went away") }
            return [Self.hex(1): [Self.era(1991, 1995)]]
        }, records: { recs })
        #expect(await store.refresh())
        failing.on = true
        #expect(await store.refresh() == false)
        #expect(await store.refresh() == false)
        #expect(store.shown(for: recs[0]) != nil)                                // the old cache stays
        #expect(notes.count == 1)
        #expect(notes.first?.contains("disk went away") == true)
        store.detach()
    }

    @Test func aStaleRefreshNeverOverwritesANewerOne() async {
        let store = MachineEraStore()
        let gate = SlowFirst()
        let recs = [Self.record(1)]
        store.attach(load: { await gate.load() }, records: { recs })
        async let first = store.refresh()           // slow: returns 1960–1965 after the second
        await Task.yield()
        let second = await store.refresh()          // fast: 1991–1995
        let firstResult = await first
        #expect(second)
        #expect(!firstResult)
        #expect(store.shown(for: recs[0])?.text.contains("1991–1995") == true)
        store.detach()
    }

    // MARK: The index's observation layer

    @Test func theLayerAgreesWithTheReferenceOnBothPaths() {
        var recs: [VideoRecord] = []
        var terms: [String: CatalogSearchIndex.ObservationTerms] = [:]
        let eras = [Self.era(1991, 1995), Self.era(1975, 1985), Self.era(1997, 1999), Self.era(1988, 1992), Self.era(2001, 2003)]
        for n in 1...200 {
            let transcript = n % 7 == 0 ? "we went early that year" : (n % 11 == 0 ? "the 1990s were fun" : nil)
            let r = Self.record(n, transcript: transcript)
            recs.append(r)
            if n % 3 != 0 {
                let e = eras[n % eras.count]
                terms[r.fullPath] = .init(words: MachineEraResolver.searchWords(era: e), years: MachineEraResolver.searchYears(era: e))
            }
        }
        let index = CatalogSearchIndex()
        index.rebuild(records: recs)
        index.setObservations(terms)
        for query in ["1990s", "90s", "early 90s", "early", "\"early 90s\"", "late 90s", "80s", "1980s", "2000s", "year:1993",
                      "decade:1970", "fun 1990s", "yearly", "1991-1995", "fused", "clip_14", "mid 70s"] {
            let tokens = CatalogSearchIndex.prepareTokens(pfTokenizeSearchQuery(query))
            let reference = recs.filter { r in
                tokens.allSatisfy { t in pfCatalogTokenMatches(t, r) || (terms[r.fullPath]?.matches(t) ?? false) }
            }
            #expect(ids(index.filter(records: recs, query: query)) == ids(reference), "\(query)")
            #expect(index.count(records: recs, query: query) == reference.count, "\(query) count")
        }
    }

    @Test func isolationTermsForAMissingPathAreInertAndRemoveRebuildClearBehave() {
        let a = Self.record(1), b = Self.record(2)
        let index = CatalogSearchIndex()
        index.rebuild(records: [a, b])
        let words = CatalogSearchIndex.ObservationTerms(words: ["1990s", "90s"], years: 1991...1995)
        index.setObservations([a.fullPath: words, "/Volumes/Gone/ghost.mov": words])
        #expect(ids(index.filter(records: [a, b], query: "90s")) == [a.id])
        index.rebuild(records: [a, b])                                     // a catalog reload keeps the layer
        #expect(ids(index.filter(records: [a, b], query: "1990s")) == [a.id])
        index.update(a)                                                     // a record edit keeps it too
        #expect(ids(index.filter(records: [a, b], query: "90s")) == [a.id])
        index.remove(fullPath: a.fullPath)
        #expect(index.observationTerms(forPath: a.fullPath) == nil)
        #expect(index.filter(records: [b], query: "90s").isEmpty)
        index.setObservations([b.fullPath: words])
        index.clear()
        #expect(index.observationTerms(forPath: b.fullPath) == nil)
    }

    // MARK: Sensor

    @Test func sensorTheStoreHoldsNoSQLNeverWritesAndExtendsNoModel() throws {
        let source = try String(contentsOf: Self.appSource("Catalog/MachineEraStore.swift"), encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for forbidden in ["SELECT ", "INSERT ", "UPDATE ", "DELETE ", "import " + "GRDB", "extension VideoScanModel", ".write(", "writeBlocking",
                          "commitSideTables", "appendProvenanceAssertion"] {
            #expect(!code.contains(forbidden), "MachineEraStore holds \(forbidden)")
        }
        let view = try String(contentsOf: Self.appSource("Catalog/InspectorDateView.swift"), encoding: .utf8)
        let line = try #require(view.range(of: "struct InspectorMachineEraLine")).lowerBound
        let body = String(view[line...])
        for forbidden in ["refresh(", ".read {", "for rec in", ".filter {", "records"] {
            #expect(!body.contains(forbidden), "the inspector's era line does \(forbidden) in its body")
        }
    }

    static func appSource(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan").appendingPathComponent(relative)
    }

    // MARK: Scale

    @Test(.tags(.scale), .timeLimit(.minutes(3)))
    func oneHundredThousandRecordsJoinIndexAndQueryWithinBudget() async {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        var eras: [String: [MachineEra]] = [:]
        for n in 1...100_000 {
            recs.append(Self.record(n, userDate: n % 4 == 0 ? "\(1960 + n % 45)" : nil))
            if n % 2 == 0 { eras[Self.hex(n)] = [Self.era(1960 + n % 45, 1964 + n % 45)] }
        }
        let index = CatalogSearchIndex()
        index.rebuild(records: recs)
        let store = MachineEraStore()
        store.onSearchTerms = { index.setObservations($0) }
        let frozen = eras
        store.attach(load: { frozen }, records: { recs })
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let words = MachineEraStore.termsByDigest(eras)
        let joinTook = clock.measure { _ = MachineEraStore.join(records: recs, eras: eras, terms: words) }
        var found = 0
        let refreshTook = await clock.measure {
            await store.refresh()
            found = index.count(records: recs, query: "1990s")
        }
        #expect(store.convergence?.total == 25_000)
        #expect(found > 0)
        print("MachineEraStore scale: 100k records / 50k eras — join \(joinTook), refresh + index + query \(refreshTook)")
        expectWithinTimingBudget("MachineEraStore main-actor join, 100k records", measured: joinTook,
                                 budget: PerformanceLane.debugCeiling(.milliseconds(400)), loadBefore: load)
        expectWithinTimingBudget("MachineEraStore refresh + index layer + a 1990s query, 100k records", measured: refreshTook,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
        store.detach()
    }
}

private final class FailSwitch: @unchecked Sendable {
    var on = false
}

/// The first load is slow and stale; the second is fast and new.
private actor SlowFirst {
    private var calls = 0
    func load() async -> [String: [MachineEra]] {
        calls += 1
        if calls == 1 {
            try? await Task.sleep(for: .milliseconds(300))
            return [String(format: "%064x", 1): [MachineEra(lo: 1960, hi: 1965, by: machineBy, at: 0, seq: 1)]]
        }
        return [String(format: "%064x", 1): [MachineEra(lo: 1991, hi: 1995, by: machineBy, at: 0, seq: 2)]]
    }
}
