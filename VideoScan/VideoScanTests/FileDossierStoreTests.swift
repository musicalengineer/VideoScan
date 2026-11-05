// FileDossierStoreTests.swift — the file dossier view, app half
// (FileDossierStore.swift, FileDossierView.swift, the three call sites;
// docs/design/file_dossier_view.md phase 1). Core's FileDossierTests and
// TechnicalReadingTests own the rules, the stored-row truth, the 100k scale
// and the corrupt-row isolation.
//
// Dimensions (CLAUDE.md rule 8):
//   TRUTH      a real cutover scene on catalog.sqlite → the PRODUCTION door
//              (FileDossierLoader.production) reads the healthy record's
//              dossier: its Technical and Patterns lines equal the ones built
//              from the record the model loaded from the same rows, a
//              journal-applied era shows with its signer, and the read
//              changes nothing (generation and records the same); a file
//              the catalog does not hold is "not stored", never empty.
//   LOGIC      (review 11/05) a nil file cancels the read in flight; going
//              away tears down the change subscription; an edit reaches the
//              open dossier after its commit (stale at 1 s, fresh by ~3–4 s);
//              the view is Equatable on (file, door); one loader per model.
//   LOGIC      the store: a newer request drops an older answer (never one
//              file's dossier beside another's); a failed read is shown in
//              words and logged once per reason; a change signal re-reads;
//              a Dossier window row re-renders when its dossier opens.
//   MEDIA      ffmpeg-made mp4/h264, mov/prores, mkv/ffv1+pcm, mxf/mpeg2,
//              avi/dv → ffprobe → the scan's OWN mapping (ScanEngine
//              .extractMetadata → VideoRecord.apply) → Technical's lines.
//   TRUTH      a real DV file with two stereo pairs (4 channels) → ffprobe →
//              the scan keeps the first stream → Audio says "first audio
//              stream: … 2 ch", never a bare "2 ch" (rule 1).
//   SENSOR     FileDossierSensorTests: the four call sites go through one
//              door; only the store reads; no records walk, no write, no
//              model extension; all groups start collapsed; no yellow.
//   SCALE      Core (100k files, one open ≈ 2 ms). WRITER quartet N/A — a reader.
// Synthetic media and names only.

import Combine
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let seated = SeatedApproach.eraA2.signer

// MARK: - TRUTH through the production door

@Suite("File dossier — the production door reads catalog.sqlite", .serialized)
@MainActor
struct FileDossierProductionTests {

    @Test("the healthy record's dossier equals the one built from the model's own record; the read writes nothing")
    func productionDoorMatchesTheLoadedRecord() async throws {
        let scene = try CutoverScene.make("file_dossier"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let preview = try await scene.sqliteLoad()
        let healthyID = PoisonedCatalogFixture.id(.healthy)
        let digest = try #require(preview.records.first { $0.id.uuidString == healthyID }.flatMap(CatalogCommit.digest(of:)))
        let line = try ObservationLine(subjectID: digest, field: "era.fused", value: "1991-1995", by: seated, at: 1_762_000_000,
                                       confidence: 0.6, evidence: ["validEraWindows": 1, "windows": [[0.0, 60.0]]], job: "TEST", unit: 0)
        try ObservationJournal(directory: scene.folder.appendingPathComponent("background/journal", isDirectory: true)).append([line])
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        _ = try #require(await scene.model.journalApplier.launchPass?.value)
        let record = try scene.record(.healthy)
        let repository = try #require(scene.model.catalogCutover.committer?.repository)
        let generation = await repository.generation
        let count = scene.model.records.count

        let loader = FileDossierLoader.production(model: scene.model)
        let dossier = try #require(try await loader.load(record.id))
        let built = FileDossier.build(record: record, digest: digest, assertions: [], now: Date())
        #expect(dossier.fileID == record.id.uuidString && dossier.digest == digest && dossier.filename == record.filename)
        #expect(dossier.technical == built.technical, "every Technical line is the stored probe columns, read the same way")
        let stored = dossier.patterns.lines.filter { !["Era", "Burned-in date"].contains($0.label) }
        let fromRecord = built.patterns.lines.filter { !["Era", "Burned-in date"].contains($0.label) }
        #expect(stored == fromRecord, "captions, transcript, OCR, people, inferred date and the run equal the record's")
        let era = try #require(dossier.patterns.line("Era"))
        #expect(era.value == "1991–1995" && era.source == "8B era, unconfirmed" && era.standing == .observation)

        #expect(try await loader.load(UUID()) == nil, "a file the catalog does not hold reads as not stored")
        #expect(FileDossierLoader.production(model: scene.model).id == loader.id, "one loader per model, never rebuilt per body")
        #expect(await repository.generation == generation, "READ ONLY: no commit")
        #expect(scene.model.records.count == count)
    }
}

// MARK: - LOGIC: the store

@Suite("File dossier — the store")
@MainActor
struct FileDossierStoreTests {

    nonisolated static func dossier(_ id: UUID, _ name: String) -> FileDossier {
        let r = VideoRecord(id: id)
        r.filename = name
        r.streamTypeRaw = "Video+Audio"
        return FileDossier.build(record: r, digest: nil, assertions: [], now: Date())
    }

    final class Notes: @unchecked Sendable {      // test-only collector, main actor only
        var lines: [String] = []
    }

    static func loader(_ load: @escaping FileDossierLoader.Load, notes: Notes = Notes(),
                       changes: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()) -> FileDossierLoader {
        FileDossierLoader(load: load, note: { notes.lines.append($0) }, changes: changes)
    }

    @Test func aNewerRequestDropsAnOlderAnswer() async throws {
        let a = UUID(), b = UUID()
        let loader = Self.loader { id in
            if id == a { try await Task.sleep(for: .milliseconds(300)) }
            return Self.dossier(id, id == a ? "A.mov" : "B.mov")
        }
        let store = FileDossierStore()
        let first = Task { await store.show(fileID: a, loader: loader) }      // main actor, like the view's .task
        try await Task.sleep(for: .milliseconds(50))
        await store.show(fileID: b, loader: loader)
        await first.value
        guard case .loaded(let shown) = store.shown else { Issue.record("not loaded: \(store.shown)"); return }
        #expect(shown.filename == "B.mov", "A's late answer is never shown beside B")
    }

    @Test func aMissingRowAndAFailedReadSaySoAndAFailureIsLoggedOnce() async throws {
        let notes = Notes()
        let store = FileDossierStore()
        await store.show(fileID: UUID(), loader: Self.loader({ _ in nil }, notes: notes))
        #expect(store.shown == .notStored)
        await store.show(fileID: nil, loader: Self.loader({ _ in nil }, notes: notes))
        #expect(store.shown == .notStored, "no catalog id: not stored, never an empty dossier")
        let failing = Self.loader({ _ in throw Refusal("catalog.sqlite is not open in this session") }, notes: notes)
        let id = UUID()
        await store.show(fileID: id, loader: failing)
        await store.reload()
        #expect(store.shown == .failed("catalog.sqlite is not open in this session"))
        #expect(notes.lines.count == 1, "one line per reason, not per read: \(notes.lines)")
        #expect(notes.lines.first?.contains("catalog.sqlite is not open") == true)
    }

    @Test func aDossierWindowRowReRendersWhenItsDossierOpens() {
        let item = CompletedActivity(id: UUID(), filename: "a.mov", path: "/Volumes/X/a.mov", vlmSeconds: 1, whisperSeconds: nil, note: nil,
                                     syncedAt: Date(), isVideoOnly: false, hasCaptions: true, hasTranscript: false, transcriptFailed: false)
        let closed = CompletedActivityRow(item: item, now: .distantPast, onShowInCatalog: { _ in })
        let open = CompletedActivityRow(item: item, now: .distantPast, isExpanded: true, onShowInCatalog: { _ in })
        #expect(closed != open, "the ▸/▾ follows the click (the row is .equatable())")
        #expect(closed == CompletedActivityRow(item: item, now: Date(), onShowInCatalog: { _ in }))
    }

    @Test func aNilFileCancelsTheReadInFlight() async throws {
        final class Ran: @unchecked Sendable { var finished = false }     // set only if the read was NOT cancelled
        let ran = Ran()
        let a = UUID()
        let loader = Self.loader { id in
            try await Task.sleep(for: .milliseconds(300))
            ran.finished = true
            return Self.dossier(id, "A.mov")
        }
        let store = FileDossierStore()
        let first = Task { await store.show(fileID: a, loader: loader) }
        try await Task.sleep(for: .milliseconds(50))
        await store.show(fileID: nil, loader: loader)
        await first.value
        try await Task.sleep(for: .milliseconds(400))
        #expect(!ran.finished, "the read begun for A was cancelled, not left to run")
        #expect(store.shown == .notStored && store.reads == 0, "never shown under no file")
    }

    @Test func disappearingTearsDownTheChangeSubscription() async throws {
        let subject = PassthroughSubject<Void, Never>()
        let store = FileDossierStore()
        await store.show(fileID: UUID(), loader: Self.loader({ id in Self.dossier(id, "A.mov") }, changes: subject.eraseToAnyPublisher()))
        #expect(store.isListening)
        store.cancel()
        #expect(!store.isListening)
        subject.send(())
        try await Task.sleep(for: .milliseconds(1500))
        #expect(store.reads == 1, "no read after the view went away")
    }

    /// Edit at t0; the committer writes it at t0 + 2 s (its debounce). Through
    /// the production timing (`afterCommit`) the open dossier still shows the
    /// committed (old) lines at 1 s and the edit by about 3–4 s.
    @Test(.timeLimit(.minutes(1)))
    func anEditShowsAfterItIsCommitted() async throws {
        final class Catalog: @unchecked Sendable {        // the fake catalog.sqlite (main actor only)
            var name = "Old.mov"
        }
        let db = Catalog()
        let edits = PassthroughSubject<Void, Never>()
        let loader = Self.loader({ id in Self.dossier(id, await MainActor.run { db.name }) },
                                 changes: FileDossierLoader.afterCommit(edits.eraseToAnyPublisher()))
        let store = FileDossierStore()
        await store.show(fileID: UUID(), loader: loader)
        let start = ContinuousClock.now
        #expect(FileDossierLoader.commitSample == CatalogCommitter.debounce + .seconds(1), "sampled one period after the committer's debounce")
        edits.send(())                                       // the edit (in memory)
        let commit = Task { try await Task.sleep(for: CatalogCommitter.debounce); db.name = "New.mov" }
        try await Task.sleep(for: .seconds(1))
        guard case .loaded(let early) = store.shown else { Issue.record("\(store.shown)"); return }
        #expect(early.filename == "Old.mov", "within 1 s the catalog still holds the old row")
        var fresh = false
        while ContinuousClock.now - start < .seconds(6) {
            if case .loaded(let d) = store.shown, d.filename == "New.mov" { fresh = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await commit.value
        let took = ContinuousClock.now - start
        #expect(fresh, "the committed edit reaches the open dossier")
        #expect(took < .seconds(5), "by about 3–4 s: \(took)")
    }

    @Test func theViewIsEqualForTheSameFileThroughTheSameDoor() {
        let loader = Self.loader { _ in nil }
        let id = UUID()
        #expect(FileDossierView(fileID: id, loader: loader) == FileDossierView(fileID: id, loader: loader))
        #expect(FileDossierView(fileID: id, loader: loader) != FileDossierView(fileID: UUID(), loader: loader))
        #expect(FileDossierView(fileID: id, loader: loader) != FileDossierView(fileID: id, loader: Self.loader { _ in nil }))
    }

    @Test func aChangeSignalReReads() async throws {
        let subject = PassthroughSubject<Void, Never>()
        let id = UUID()
        let store = FileDossierStore()
        await store.show(fileID: id, loader: Self.loader({ id in Self.dossier(id, "A.mov") }, changes: subject.eraseToAnyPublisher()))
        #expect(store.reads == 1)
        subject.send(())
        for _ in 0..<40 where store.reads < 2 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(store.reads == 2, "the view fills in as results land")
    }
}

// MARK: - MEDIA: the technical readings over the matrix

@Suite("File dossier — technical readings over the media matrix", .serialized)
@MainActor
struct FileDossierMediaMatrixTests {

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var args: [String]
        var container: String
        var codec: String
        var oneLiner: String
        var size: String
        var testDescription: String { name }
    }

    nonisolated static let src = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2"]
    nonisolated static let cases: [Case] = [
        Case(name: "test_dossier_h264.mp4", args: src + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"],
             container: "MP4:", codec: "H.264/AVC", oneLiner: "h264 320×240 25 fps in mp4", size: "VGA-class"),
        Case(name: "test_dossier_prores.mov", args: src + ["-c:v", "prores_ks", "-c:a", "pcm_s16le", "-shortest"],
             container: "QuickTime wrapper", codec: "TRANSFER", oneLiner: "ProRes transfer master 320×240", size: "VGA-class"),
        Case(name: "test_dossier_ffv1.mkv", args: src + ["-c:v", "ffv1", "-c:a", "pcm_s16le", "-shortest"],
             container: "Matroska", codec: "TRANSFER", oneLiner: "FFV1 transfer master 320×240", size: "VGA-class"),
        Case(name: "test_dossier_mpeg2.mxf",
             args: ["-f", "lavfi", "-i", "testsrc=size=720x576:rate=25:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
                    "-c:v", "mpeg2video", "-b:v", "8M", "-c:a", "pcm_s16le", "-shortest"],
             container: "MXF", codec: "MPEG-2", oneLiner: "DVD / DVD-camcorder MPEG-2 720×576", size: "PAL"),
        Case(name: "test_dossier_dv.avi",
             args: ["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001:duration=2", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
                    "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le", "-shortest"],
             container: "AVI", codec: "carrier floor 1995", oneLiner: "DV camcorder/deck capture, NTSC 720×480", size: "NTSC"),
    ]

    @Test("ffprobe → the scan's own mapping → Technical says what the file is", .timeLimit(.minutes(2)), arguments: cases)
    func technicalReadings(_ c: Case) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies (Brewfile)")
        let dir = try CleanupTestMedia.makeScratchDir("dossier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(c.name)
        try CleanupTestMedia.runFFmpeg(c.args, output: url.path)
        let (probe, stderr) = await ScanEngine.runFFProbe(url: url)
        let record = VideoRecord()
        record.filename = c.name
        record.ext = url.pathExtension
        record.fullPath = url.path
        record.apply(ScanEngine.extractMetadata(probe: try #require(probe, "ffprobe failed: \(stderr)")))
        let t = FileDossier.build(record: record, digest: nil, assertions: [], now: Date()).technical

        #expect(t.line("Container")?.reading?.contains(c.container) == true, "\(c.name): \(t.line("Container").debugDescription)")
        #expect(t.line("Video codec")?.reading?.contains(c.codec) == true, "\(c.name): \(t.line("Video codec").debugDescription)")
        #expect(t.line("Frame size")?.reading?.contains(c.size) == true, "\(c.name): \(t.line("Frame size").debugDescription)")
        #expect(t.summary.hasPrefix(c.oneLiner), "\(c.name): \(t.summary)")
        #expect(t.line("Audio")?.value.hasPrefix("first audio stream: " + record.audioCodec) == true)
        #expect(t.line("Duration / rate") != nil)
        #expect(t.lines.allSatisfy { $0.standing == .fact || $0.label == "DV clock" })
        #expect((t.line("DV clock") != nil) == (record.videoCodec == "dvvideo"), "only DV carries the DV clock line")
    }
}

// MARK: - TRUTH: a 4-channel DV file through the real probe

@Suite("File dossier — a partial probe field never reads as the whole", .serialized)
@MainActor
struct FileDossierPartialFieldTests {

    @Test("a DV file with two stereo pairs (4 channels) never reads as plain \"2 ch\"", .timeLimit(.minutes(2)))
    func fourChannelDVSaysFirstStream() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies (Brewfile)")
        let dir = try CleanupTestMedia.makeScratchDir("dossier4ch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test_dossier_dv_4ch.avi")
        try CleanupTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=32000",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=2:sample_rate=32000",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-ac", "2",
            "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le", "-shortest"], output: url.path)
        let (probe, stderr) = await ScanEngine.runFFProbe(url: url)
        let output = try #require(probe, "ffprobe failed: \(stderr)")
        let audioStreams = (output.streams ?? []).filter { $0.codec_type == "audio" }
        #expect(audioStreams.count == 2 && audioStreams.allSatisfy { $0.channels == 2 }, "the fixture really carries 4 channels in two pairs")
        let record = VideoRecord()
        record.filename = url.lastPathComponent
        record.ext = "avi"
        record.apply(ScanEngine.extractMetadata(probe: output))
        #expect(record.audioChannels == "2", "the scan keeps the first stream only — the premise of this test")
        let audio = try #require(FileDossier.build(record: record, digest: nil, assertions: [], now: Date()).technical.line("Audio"))
        #expect(audio.value == "first audio stream: pcm_s16le 32000 Hz 2 ch", "\(audio.value)")
        #expect(audio.value.range(of: #"^\S+ \d+ Hz \d+ ch$"#, options: .regularExpression) == nil, "never the bare total form")
        #expect(audio.source == "ffprobe (first audio stream)")
    }
}

// MARK: - SENSOR: one door, four call sites

@Suite("File dossier — sensors")
struct FileDossierSensorTests {

    private func code(_ file: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: file))
    }

    @Test func theFourCallSitesGoThroughOneDoor() throws {
        // 1. The inspector: the host passes the door; the section shows the one view.
        #expect(try code("CatalogHelpers.swift").contains("fileDossiers: FileDossierLoader.production(model: model)"))
        #expect(try code("InspectorPanel+Sections.swift").contains("InspectorDossierView(record: rec, loader: fileDossiers)"))
        #expect(try code("InspectorDossierView.swift").contains("FileDossierView(fileID: record.id, loader: loader).equatable()"))
        // 2. The Dossier window: a completed row opens in place; the door is taken once, at init.
        #expect(try code("DossierDashboardView.swift").contains("FileDossierView(fileID: opened, loader: dossiers).equatable()"))
        #expect(try code("DossierDashboardView.swift").contains("self.dossiers = FileDossierLoader.production(model: model)"))
        // 4. The Media File Operations window: an Analyze / Transcribe / Captions
        //    row expands to the file's dossier (Rick: "click on the file in the MFO window").
        #expect(try code("AnalyzeJob.swift").contains("FileDossierView(fileID: record.id, loader: dossiers).equatable()"))
        #expect(try code("AnalyzeJob.swift").contains("self.dossiers = FileDossierLoader.production(model: model)"))
        #expect(try code("AnalyzeJob.swift").contains("MediaFileOperationOwnDetail"))
        #expect(try code("MediaFileOperations.swift").contains(#"static let analyze = Self("analyze", hasDetailView: true,"#))
        // 3. The Results sheet.
        #expect(try code("AnalysisResultsStore.swift").contains("dossiers: FileDossierLoader.production(model: model)"))
        #expect(try code("AnalysisResultsSheet.swift").contains("FileDossierView(fileID: row.recordID, loader: loader).equatable()"))

        // Nobody else builds the view, a loader, or reads a dossier.
        var views: [String] = [], loaders: [String] = [], reads: [String] = []
        for source in SourceTree.appSources {
            let text = SourceTree.strippingComments(try String(contentsOf: source.url, encoding: .utf8))
            let name = source.url.lastPathComponent
            if text.contains("FileDossierView(fileID:") { views.append(name) }
            if text.range(of: #"FileDossierLoader\(\s*load:"#, options: .regularExpression) != nil { loaders.append(name) }
            if text.contains("FileDossier.read(") { reads.append(name) }
        }
        #expect(Set(views) == ["InspectorDossierView.swift", "DossierDashboardView.swift", "AnalysisResultsSheet.swift", "AnalyzeJob.swift"], "\(views)")
        #expect(loaders == ["FileDossierStore.swift"], "one door: \(loaders)")
        #expect(reads == ["FileDossierStore.swift"], "one read: \(reads)")
    }

    @Test func theViewAndTheStoreAreReadOnlyAndDoNoRecordsWork() throws {
        let walks = ["model.records", "records.filter", "records.map", "records.first", "records.count", "for r in records"]
        for file in ["FileDossierView.swift", "FileDossierStore.swift", "InspectorDossierView.swift"] {
            let src = try code(file)
            for walk in walks { #expect(!src.contains(walk), "\(file) walks records: `\(walk)`") }
            for forbidden in ["SELECT ", "INSERT", "UPDATE ", "DELETE", "writeBlocking", ".write(as", "extension VideoScanModel"] {
                #expect(!src.contains(forbidden), "\(file): `\(forbidden)`")
            }
        }
        let store = try code("FileDossierStore.swift")
        #expect(store.contains("repository.read {"), "reads through the session's repository reader")
        #expect(store.contains("Task.detached"), "loads off the main actor")
        #expect(!(try code("FileDossierView.swift")).contains("model."), "the view reads the store only")
        // The Dossier window resolves the file once, at the click, through the path index.
        #expect(try code("DossierDashboardView.swift").contains("model.record(forPath: item.path)?.id"))
    }

    @Test func allGroupsStartCollapsedAndTheColoursAreGreyAndBlue() throws {
        let view = try code("FileDossierView.swift")
        #expect(view.contains("@State private var expanded: Set<FileDossier.Layer> = []"), "Rick 11/05: all three start collapsed")
        for colour in [".yellow", ".orange", ".green", ".red", ".purple", ".teal", ".indigo"] {
            #expect(!view.contains(colour), "DECISIONS 2026-11-03: grey and blue, never \(colour)")
        }
    }
}
