// MachineEstimateFoldersTests.swift — Catalog ▸ Show ▸ Folders by Machine
// Estimate, and the File Journey's "Estimated era" line (Rick 2026-11-13).
// Core's MachineEraResolverTests own the filing rule's boundaries and the
// sentence; these pin what the app does with them.
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      a row whose content has an era files under its year or its
//              decade folder; copies fold under their recording as in any
//              folder; the newest era decides; the folders come oldest first.
//   TRUTH      a row with no era is in no folder (never guessed into one);
//              a sampled `v1:` hash never matches an era; the journey shows
//              the line only when an era is handed in, dated when the machine
//              made it, and its words say "not confirmed".
//   ISOLATION  no eras → no folders; an era for a content not in the catalog
//              is inert; the setting reads off unless a plist true is stored.
//   SCALE      100k rows, 50k with an era, inside the join's Debug budget.
//   SENSOR     the estimate file writes nothing and names no store; the
//              folder edit paths refuse while the index is estimated.
//   MEDIA      N/A — no media is opened. WRITER quartet: N/A (a view).
// Synthetic names and digests only.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias Row = FootageFolders.Row

private let by8 = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

private func row(_ name: String, digest: String?, size: Int64 = 1_000, id: UUID = UUID()) -> Row {
    Row(id: id, digest: digest, sizeBytes: size, durationSeconds: 60,
        keys: FootageFolders.SortKeys(filename: name, duration: 60, size: size))
}

private func era(_ lo: Int, _ hi: Int, seq: Int64 = 1, burned: [Int] = []) -> MachineEra {
    MachineEra(lo: lo, hi: hi, by: by8, at: 1_762_000_000, seq: seq, burnedInYears: burned)
}

private func code(_ name: String) throws -> String {
    try SourceTree.strippingComments(SourceTree.appSource(named: name))
}

// MARK: - Logic and truth

@Suite("Machine-estimate folders — which file goes where")
struct MachineEstimateFoldersLogicTests {

    @Test func aRowFilesUnderItsDecadeOrItsYearAndTheRestStayLoose() throws {
        let eighties = row("beach.mov", digest: hex(1))
        let ninety1 = row("birthday.mov", digest: hex(2))
        let noEra = row("unknown.mov", digest: hex(3))
        let eras = [hex(1): [era(1980, 1995)], hex(2): [era(1991, 1991, burned: [1991])]]

        let events = MachineEstimateFolders.events(rows: [eighties, ninety1, noEra], eras: eras)
        #expect(events.map(\.title) == ["1980s (estimated)", "1991 (estimated)"])
        #expect(events.allSatisfy { $0.kind == .other && $0.dateWords == MachineEstimateWords.folderDateWords })

        let index = FootageFolders.index(rows: [eighties, ninety1, noEra], events: events)
        #expect(index.folders.count == 2)
        #expect(index.folder(containing: eighties.id)?.title == "1980s (estimated)")
        #expect(index.folder(containing: ninety1.id)?.title == "1991 (estimated)")
        #expect(index.folders(of: noEra.id).isEmpty, "a file with no estimate is never guessed into a folder")
    }

    @Test func aCopyFoldsUnderItsRecordingInsideTheEstimateFolder() throws {
        let original = row("tape.mov", digest: hex(7), size: 5_000)
        let copy = row("tape copy.mov", digest: hex(7), size: 5_000)
        let events = MachineEstimateFolders.events(rows: [original, copy], eras: [hex(7): [era(1990, 2000)]])
        let index = FootageFolders.index(rows: [original, copy], events: events)

        #expect(events.count == 1)
        #expect(events.first?.contentKeys.count == 1, "one content, one key — however many copies")
        let folder = try #require(index.folder(containing: original.id))
        #expect(folder.title == "1990s (estimated)")
        #expect(folder.summary.files == 2)
        #expect(folder.summary.copies == 1)
    }

    @Test func theNewestEraDecides() {
        let r = row("clip.mov", digest: hex(9))
        // MachineEraStore keeps each content's eras newest first.
        let events = MachineEstimateFolders.events(rows: [r], eras: [hex(9): [era(2000, 2010, seq: 9), era(1970, 1980, seq: 2)]])
        #expect(events.map(\.title) == ["2000s (estimated)"])
    }

    @Test func aSampledHashNeverMatchesAndAnUppercaseDigestDoes() {
        let sampled = row("sampled.mov", digest: "v1:" + hex(4))
        let upper = row("upper.mov", digest: hex(0xABCDEF).uppercased())
        let events = MachineEstimateFolders.events(rows: [sampled, upper],
                                                   eras: [hex(4): [era(1980, 1990)], hex(0xABCDEF): [era(1960, 1970)]])
        #expect(events.map(\.title) == ["1960s (estimated)"], "only a whole-file SHA-256 names a content")
        #expect(events.first?.contentKeys == [upper.contentKey])
    }

    @Test func folderIDsAreStableAndAYearIsNotItsDecade() {
        let decade = MachineEstimateFolders.folderID(.decade(1990))
        #expect(decade == MachineEstimateFolders.folderID(.decade(1990)), "the same folder has the same id on every launch")
        #expect(decade != MachineEstimateFolders.folderID(.year(1990)))
        #expect(decade != MachineEstimateFolders.folderID(.decade(1980)))
    }

    /// Codex #290: an estimate folder's id must be one `UUID()` cannot make,
    /// and every one of them — and none of Rick's — answers the id test.
    @Test func anEstimateFolderIDCanNeverBeOneOfRicks() {
        let made: [UUID] = [.year(0), .year(1991), .decade(1800), .decade(2200), .year(-5), .decade(99_999_999), .year(Int.max)]
            .map(MachineEstimateFolders.folderID)
        for id in made + [MachineEstimateFolders.unknownFolderID] {
            #expect(MachineEstimateFolders.isEstimateFolder(id), "\(id)")
            let b = id.uuid
            #expect(b.6 >> 4 != 4, "never a version-4 UUID: \(id)")
            #expect(b.8 >> 6 != 0b10, "never the RFC variant UUID() uses: \(id)")
        }
        for _ in 0..<10_000 { #expect(!MachineEstimateFolders.isEstimateFolder(UUID())) }
        // The shape the first cut used — a valid v4 UUID Rick's store could hold — is not ours.
        let v4Shaped = UUID(uuidString: "E57A0000-0000-4000-8000-000100001991")
        #expect(v4Shaped.map(MachineEstimateFolders.isEstimateFolder) == false)
    }

    /// Codex #290, declined as a defect and pinned as the design: a version
    /// made from an estimated recording (a transcode, a trim) is the same
    /// footage and folds under it, as in any folder — the legend says so.
    /// Unrelated content with no era stays loose.
    @Test func aVersionWithNoEraFollowsTheRecordingItWasMadeFrom() {
        let parent = row("source.mov", digest: hex(1))
        var child = row("clip.mov", digest: hex(2))
        child.derivedFrom = parent.id
        let stranger = row("other.mov", digest: hex(3))
        let rows = [parent, child, stranger]
        let events = MachineEstimateFolders.events(rows: rows, eras: [hex(1): [era(1980, 1995)]])
        let index = FootageFolders.index(rows: rows, events: events)
        #expect(events.first?.contentKeys == [parent.contentKey], "only the content with an era is filed")
        #expect(index.folder(containing: child.id)?.title == "1980s (estimated)", "its version rides with it")
        #expect(index.folders(of: stranger.id).isEmpty)
        #expect(MachineEstimateWords.legend.contains("unless it was made from one inside"))
    }

    @Test func theIndexSaysItIsEstimatedOnlyWhenTold() {
        let r = row("clip.mov", digest: hex(1))
        var index = FootageFolders.index(rows: [r], events: MachineEstimateFolders.events(rows: [r], eras: [hex(1): [era(1980, 1990)]]))
        #expect(!index.estimated, "the join itself never claims it; the model sets it")
        let plain = index
        index.estimated = true
        #expect(index != plain, "flipping the view is a change the table must see")
    }
}

// MARK: - Isolation

@Suite("Machine-estimate folders — isolation")
struct MachineEstimateFoldersIsolationTests {

    @Test func noErasMeansNoFolders() {
        let r = row("clip.mov", digest: hex(1))
        #expect(MachineEstimateFolders.events(rows: [r], eras: [:]).isEmpty)
        #expect(MachineEstimateFolders.events(rows: [], eras: [hex(1): [era(1980, 1990)]]).isEmpty,
                "an era for a content the catalog does not hold makes no folder")
        #expect(MachineEstimateFolders.events(rows: [r], eras: [hex(1): []]).isEmpty, "an empty era list is no era")
    }

    @Test func theSettingIsOffUnlessStoredOn() throws {
        let suite = "test.estimateFolders.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!MachineEstimateFolders.isOn(defaults), "off by default")
        defaults.set("garbage", forKey: MachineEstimateFolders.settingKey)
        #expect(!MachineEstimateFolders.isOn(defaults))
        MachineEstimateFolders.set(true, defaults)
        #expect(MachineEstimateFolders.isOn(defaults))
        MachineEstimateFolders.set(false, defaults)
        #expect(!MachineEstimateFolders.isOn(defaults))
    }
}

// MARK: - The File Journey line

private let neutral: VolumeSafetyResolver = { _ in VolumeSafety.unknown }

@MainActor
private func liveRecord() throws -> (VideoRecord, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_estimate_journey_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("clip.mov")
    try Data(repeating: 1, count: 2048).write(to: url)
    let r = VideoRecord()
    r.filename = "clip.mov"
    r.fullPath = url.path
    r.directory = dir.path
    r.ext = "mov"
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.sizeBytes = 2048
    r.dateModifiedRaw = Date(timeIntervalSince1970: 1_700_000_000)
    return (r, dir)
}

@Suite("File Journey — the machine's estimated era", .serialized)
@MainActor
struct FileJourneyMachineEraTests {

    @Test func theLineShowsWhenAnEraIsHandedInAndSaysNotConfirmed() throws {
        let (rec, dir) = try liveRecord()
        defer { try? FileManager.default.removeItem(at: dir) }
        let observed = Date(timeIntervalSince1970: 1_762_000_000)
        let line = JourneyMachineEra(sentence: MachineEraResolver.journeySentence(era: era(1980, 1995), rickYear: nil), observed: observed)

        let journey = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: neutral, machineEra: line)

        let event = try #require(journey.events.first { $0.kind == .machineEstimate })
        #expect(event.sentence.hasPrefix("Estimated era: 1980–1995"), Comment(rawValue: event.sentence))
        #expect(event.sentence.contains("not confirmed"), "a guess says it is a guess: \(event.sentence)")
        #expect(event.timestamp == observed, "dated when the machine made the guess, never at the era it guessed")
        #expect(journey.events.first?.sentence.hasPrefix("File dated") == true, "the file's own date is still the first line")
        #expect(journey.events.last?.sentence == "Now at \(rec.fullPath)", "and where the file is now is still the last")
    }

    @Test func noEraNoLine() throws {
        let (rec, dir) = try liveRecord()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journey = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: neutral)
        #expect(!journey.events.contains { $0.kind == .machineEstimate })
        #expect(!journey.events.contains { $0.sentence.contains("Estimated era") })
    }

    @Test func theStoreAnswersOnlyForAContentWithAnEra() async throws {
        let store = MachineEraStore()
        let (rec, dir) = try liveRecord()
        defer { try? FileManager.default.removeItem(at: dir) }
        rec.contentFixity = ContentFixity(digest: hex(42), byteCount: rec.sizeBytes,
                                          stamp: FileIdentityStamp(device: 1, inode: 42, size: rec.sizeBytes, mtimeNs: 0))
        let digest = try #require(CatalogCommit.digest(of: rec))
        #expect(store.journey(for: rec) == nil, "nothing read yet — nothing said")

        store.attach(load: { [digest: [era(1991, 1991, burned: [1991])]] }, records: { [rec] })
        #expect(await store.refresh())
        let shown = try #require(store.journey(for: rec))
        #expect(shown.sentence.hasPrefix("Estimated era: 1991 —"), Comment(rawValue: shown.sentence))
        #expect(shown.sentence.contains("On-screen years read: 1991."), Comment(rawValue: shown.sentence))
        #expect(shown.observed == Date(timeIntervalSince1970: 1_762_000_000))
        store.detach()
    }
}

// MARK: - Scale

@Suite("Machine-estimate folders — scale")
struct MachineEstimateFoldersScaleTests {

    /// 100k rows, every second one with an era spread over 12 decades and a
    /// few hundred exact years: building the folders and the join.
    @Test func hundredThousandRowsUnderBudget() {
        var rows: [Row] = []
        rows.reserveCapacity(100_000)
        var eras: [String: [MachineEra]] = [:]
        eras.reserveCapacity(50_000)
        for i in 0..<100_000 {
            rows.append(row("clip\(i).mov", digest: hex(i), size: Int64(1_000 + i)))
            guard i % 2 == 0 else { continue }
            let lo = 1900 + (i / 2) % 120
            eras[hex(i)] = [i % 20 == 0 ? era(lo, lo) : era(lo, lo + 10 + (i % 3) * 5)]
        }
        let load = TimingBudget.sampleLoad()
        let start = ContinuousClock.now
        let events = MachineEstimateFolders.events(rows: rows, eras: eras)
        let built = ContinuousClock.now - start
        let joinStart = ContinuousClock.now
        let index = FootageFolders.index(rows: rows, events: events)
        let joined = ContinuousClock.now - joinStart

        #expect(events.reduce(0) { $0 + $1.contentKeys.count } == 50_000, "every row with an era is in exactly one folder")
        #expect(index.folders.count == events.count)
        #expect(index.foldersOf.count == 50_000)
        expectWithinTimingBudget("MachineEstimateFolders.events 100k rows / 50k eras",
                                 measured: built, budget: PerformanceLane.debugCeiling(.milliseconds(500)), loadBefore: load)
        expectWithinTimingBudget("FootageFolders.index 100k rows under estimate folders",
                                 measured: joined, budget: PerformanceLane.debugCeiling(.milliseconds(1_500)), loadBefore: load)
    }
}

// MARK: - Sensors

@Suite("Machine-estimate folders — sensors")
struct MachineEstimateFoldersSensorTests {

    @Test func theEstimateViewWritesNothing() throws {
        let source = try code("MachineEstimateFolders.swift")
        for word in ["EventsDecisionStore", "CatalogCommit", "commit(", "userDate", "confirm(", "FileManager"] {
            #expect(!source.contains(word), "the estimate view is a view: it must not name \(word)")
        }
    }

    @Test func everyFolderEditRefusesWhileTheFoldersAreEstimates() throws {
        let drop = try code("CatalogContent+FolderDrop.swift")
        #expect(drop.contains("guard !MachineEstimateFolders.isEstimateFolder(folderID) else"), "a drop on an estimate folder files nothing")
        let labels = try code("CatalogContent+FolderLabels.swift")
        #expect(labels.contains("if MachineEstimateFolders.isEstimateFolder(id)"), "an estimate folder's menu offers Open only")
        let table = try code("CatalogContent+FolderTable.swift")
        #expect(table.contains("return folder.flatMap { MachineEstimateFolders.isEstimateFolder($0) ? nil : $0 }"),
                "no Move from / Remove from an estimate folder")
        // Codex #290: the gates ask the ROW's id, never a flag that can move ahead of the display.
        for source in [drop, labels] { #expect(!source.contains("index.estimated")) }
        #expect(try code("ContentView.swift").contains("model.setFootageFoldersEstimated(false)"),
                "showing one of Rick's own folders leaves the estimate view")
    }

    @Test func theJoinTakesRicksFoldersOrTheEstimatesNeverBoth() throws {
        let snapshot = try code("FootageFoldersSnapshot.swift")
        #expect(snapshot.contains("let own = estimated ? [] : FootageFolders.Event.events("))
        #expect(snapshot.contains("index.estimated = estimated"))
    }

    @Test func theShowMenuHasTheToggleAndThePill() throws {
        #expect(try code("CatalogToolbar.swift").contains("MachineEstimateFoldersToggle("))
        var state = CatalogShowingSummary.State()
        state.footageFolders = true
        #expect(!CatalogShowingSummary.pills(for: state).map(\.text).contains(MachineEstimateWords.pill))
        state.estimateFolders = true
        #expect(CatalogShowingSummary.pills(for: state).map(\.text).contains(MachineEstimateWords.pill))
        state.footageFolders = false
        #expect(!CatalogShowingSummary.pills(for: state).map(\.text).contains(MachineEstimateWords.pill),
                "no folder view, no estimate pill")
    }
}
