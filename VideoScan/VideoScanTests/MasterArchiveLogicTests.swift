// MasterArchiveLogicTests.swift
// LOGIC dimension (feature-test checklist item 1) for Master Archive +
// Promote to Archive: the pure resolver matrix, slug/extension hardening,
// canonical containment, manifest CSV escaping + parsing, date-hint rules,
// designation persistence in the catalog snapshot, Initialize idempotence,
// the refuse-without-master path, and the Promote journey stamp.
// (docs/archive_promotion_workflow.md §2, §3, §6)

import Foundation
import Testing
@testable import VideoScan

// MARK: - Resolver matrix

@Suite("Master Archive — path resolver")
struct ArchivePathResolverTests {

    private func facts(_ st: StreamType, _ name: String, _ hint: ArchiveDateHint,
                       ext: String? = nil, low: Bool = false) -> ArchivePathResolver.RecordFacts {
        ArchivePathResolver.RecordFacts(streamType: st, filename: name,
                                        ext: ext ?? (name as NSString).pathExtension,
                                        dateHint: hint, dateIsLowConfidence: low)
    }

    @Test("full date → bucket/decade/year/YYYY-MM-DD_slug.ext")
    func fullDate() {
        let f = facts(.videoAndAudio, "Summer Vacation.mov", .day(year: 1992, month: 7, day: 15))
        #expect(ArchivePathResolver.baseRelativePath(facts: f)
                == "30_Video/1990-1999/1992/1992-07-15_Summer-Vacation.mov")
    }

    @Test("month-only → xx day")
    func monthOnly() {
        let f = facts(.videoOnly, "clip.mxf", .month(year: 1975, month: 12))
        #expect(ArchivePathResolver.baseRelativePath(facts: f)
                == "30_Video/1970-1979/1975/1975-12-xx_clip.mxf")
    }

    @Test("year-only → year folder, xx-xx")
    func yearOnly() {
        let f = facts(.audioOnly, "Grandpa Voice.wav", .year(1975))
        #expect(ArchivePathResolver.baseRelativePath(facts: f)
                == "20_Audio/1970-1979/1975/1975-xx-xx_Grandpa-Voice.wav")
    }

    @Test("decade-only → decade root, no year folder")
    func decadeOnly() {
        let f = facts(.videoAndAudio, "Rick Guitar.mov", .decade(startYear: 1990))
        #expect(ArchivePathResolver.baseRelativePath(facts: f)
                == "30_Video/1990-1999/xxxx-xx-xx_Rick-Guitar.mov")
    }

    @Test("undated → bucket/Undated/xxxx-xx-xx_slug")
    func undated() {
        let f = facts(.videoAndAudio, "tape7.dv", .unknown)
        #expect(ArchivePathResolver.baseRelativePath(facts: f)
                == "30_Video/Undated/xxxx-xx-xx_tape7.dv")
    }

    @Test("bucket by stream type: audio→20, video/videoOnly/other→30")
    func buckets() {
        func bucket(_ t: StreamType) -> String {
            ArchivePathResolver.bucket(for: t, medium: .audioVisual)
        }
        #expect(bucket(.audioOnly) == "20_Audio")
        #expect(bucket(.videoAndAudio) == "30_Video")
        #expect(bucket(.videoOnly) == "30_Video")
        #expect(bucket(.ffprobeFailed) == "30_Video")
    }

    @Test("decade folder is the full YYYY-YYYY range (1940s footage too)")
    func decadeRange() {
        #expect(ArchivePathResolver.folder(for: .videoAndAudio, hint: .year(1944)) == "30_Video/1940-1949/1944")
        #expect(ArchivePathResolver.folder(for: .videoAndAudio, hint: .year(2009)) == "30_Video/2000-2009/2009")
    }

    @Test("slug cleaning: spaces→dash, punctuation collapsed, trimmed, capped, empty→untitled")
    func slugCleaning() {
        #expect(ArchivePathResolver.slug(from: "Summer  Vacation!! (Tape 7)") == "Summer-Vacation-Tape-7")
        #expect(ArchivePathResolver.slug(from: "  --hello--  ") == "hello")
        #expect(ArchivePathResolver.slug(from: "") == "untitled")
        #expect(ArchivePathResolver.slug(from: "!!!") == "untitled")
        #expect(ArchivePathResolver.slug(from: "under_score_ok") == "under_score_ok")
        let long = String(repeating: "a", count: 200)
        #expect(ArchivePathResolver.slug(from: long).count == 80)
    }

    @Test("curated title wins over the filename stem when present")
    func titleWins() {
        #expect(ArchivePathResolver.slugSource(title: "Christmas 1975", filename: "IMG_0001.mov") == "Christmas 1975")
        #expect(ArchivePathResolver.slugSource(title: "   ", filename: "IMG_0001.mov") == "IMG_0001")
        #expect(ArchivePathResolver.slugSource(title: nil, filename: "IMG_0001.mov") == "IMG_0001")
    }

    @Test("slug injection attempts cannot produce path components or control chars",
          arguments: [
            "../../etc/passwd", "..", "/absolute/path", "a/b/c", "name\nnewline",
            "tab\tname", "quote\"comma,", "null\u{0}byte", "back\\slash", "colon:name",
            "dots...only", ". .", "\u{7F}del"
          ])
    func slugInjection(raw: String) {
        let s = ArchivePathResolver.slug(from: raw)
        #expect(!s.contains("/"))
        #expect(!s.contains("\\"))
        #expect(!s.contains(".."))
        #expect(!s.contains(":"))
        #expect(s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F })
        #expect(s != "." && s != "..")
        #expect(!s.isEmpty)
    }

    @Test("extension normalization is strict ASCII alnum, lower-case, ≤16, no separators")
    func extensionStrict() {
        #expect(ArchivePathResolver.normalizedExtension(".MOV", filename: "x") == "mov")
        #expect(ArchivePathResolver.normalizedExtension("", filename: "x.MXF") == "mxf")
        #expect(ArchivePathResolver.normalizedExtension("", filename: "noext") .isEmpty)
        #expect(ArchivePathResolver.normalizedExtension("mov/../x", filename: "x") == "movx")
        #expect(ArchivePathResolver.normalizedExtension("m\nov", filename: "x") == "mov")
        #expect(ArchivePathResolver.normalizedExtension(String(repeating: "a", count: 40), filename: "x").count == 16)
    }

    @Test("a filename made only of traversal parts still lands INSIDE the bucket")
    func traversalFilenameStaysContained() {
        let f = facts(.videoAndAudio, "../../..", .unknown, ext: "../..")
        let rel = ArchivePathResolver.baseRelativePath(facts: f)
        #expect(rel == "30_Video/Undated/xxxx-xx-xx_untitled")
        #expect(ArchivePathResolver.isInside(path: "/tmp/root/" + rel, root: "/tmp/root"))
    }

    @Test("collision suffix _NN via the injected exists check")
    func collision() {
        let f = facts(.videoAndAudio, "Summer.mov", .day(year: 1992, month: 7, day: 15))
        let taken: Set<String> = [
            "/root/30_Video/1990-1999/1992/1992-07-15_Summer.mov",
            "/root/30_Video/1990-1999/1992/1992-07-15_Summer_02.mov"
        ]
        let rel = ArchivePathResolver.resolveRelativePath(facts: f, rootPath: "/root") { taken.contains($0) }
        #expect(rel == "30_Video/1990-1999/1992/1992-07-15_Summer_03.mov")
        let free = ArchivePathResolver.resolveRelativePath(facts: f, rootPath: "/root") { _ in false }
        #expect(free == "30_Video/1990-1999/1992/1992-07-15_Summer.mov")
    }

    @Test("collision suffix on an extensionless name")
    func collisionNoExt() {
        let f = facts(.videoAndAudio, "raw", .unknown, ext: "")
        let rel = ArchivePathResolver.resolveRelativePath(facts: f, rootPath: "/root") {
            $0 == "/root/30_Video/Undated/xxxx-xx-xx_raw"
        }
        #expect(rel == "30_Video/Undated/xxxx-xx-xx_raw_02")
    }

    @Test("component-wise containment: no prefix-string tricks, dot-dot collapsed, root never contains all")
    func containment() {
        #expect(ArchivePathResolver.isInside(path: "/Volumes/A/Breen_Family_Archive/x.mov", root: "/Volumes/A/Breen_Family_Archive"))
        #expect(!ArchivePathResolver.isInside(path: "/Volumes/A/Breen_Family_Archive2/x.mov", root: "/Volumes/A/Breen_Family_Archive"))
        #expect(!ArchivePathResolver.isInside(path: "/Volumes/AB/x.mov", root: "/Volumes/A"))
        #expect(!ArchivePathResolver.isInside(path: "/Volumes/A/arch/../../B/x.mov", root: "/Volumes/A/arch"))
        #expect(ArchivePathResolver.isInside(path: "/Volumes/A/arch/sub/../x.mov", root: "/Volumes/A/arch"))
        #expect(!ArchivePathResolver.isInside(path: "/anything", root: "/"))
        #expect(ArchivePathResolver.isInside(path: "/Volumes/A/arch", root: "/Volumes/A/arch/"))
    }
}

// MARK: - Date hint rules

@Suite("Master Archive — date hint")
struct ArchiveDateHintTests {

    @Test("user date outranks inferred, at its entered precision")
    func userDateWins() {
        let (h, low) = ArchivePathResolver.dateHint(userDate: "1992", inferredRecordDate: Date(), inferredDateConfidence: 0.99)
        #expect(h == .year(1992)); #expect(!low)
        #expect(ArchivePathResolver.dateHint(userDate: "1992-06", inferredRecordDate: nil, inferredDateConfidence: nil).hint == .month(year: 1992, month: 6))
        #expect(ArchivePathResolver.dateHint(userDate: "1992-06-14", inferredRecordDate: nil, inferredDateConfidence: nil).hint == .day(year: 1992, month: 6, day: 14))
    }

    @Test("inferred date used only at ≥ 0.6 confidence; below → unknown + low flag")
    func inferredThreshold() throws {
        var comps = DateComponents(); comps.year = 2005; comps.month = 3; comps.day = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let d = try #require(cal.date(from: comps))
        let ok = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: d, inferredDateConfidence: 0.6)
        #expect(ok.hint == .day(year: 2005, month: 3, day: 9)); #expect(!ok.lowConfidence)
        let low = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: d, inferredDateConfidence: 0.59)
        #expect(low.hint == .unknown); #expect(low.lowConfidence)
        let none = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: nil, inferredDateConfidence: nil)
        #expect(none.hint == .unknown); #expect(!none.lowConfidence)
    }

    @Test("filename prefix + manifest date shapes")
    func prefixes() {
        #expect(ArchiveDateHint.day(year: 1992, month: 7, day: 5).filenamePrefix == "1992-07-05")
        #expect(ArchiveDateHint.month(year: 1992, month: 7).filenamePrefix == "1992-07-xx")
        #expect(ArchiveDateHint.year(1992).filenamePrefix == "1992-xx-xx")
        #expect(ArchiveDateHint.decade(startYear: 1990).filenamePrefix == "xxxx-xx-xx")
        #expect(ArchiveDateHint.unknown.filenamePrefix == "xxxx-xx-xx")
        #expect(ArchiveDateHint.unknown.manifestDate .isEmpty)
        #expect(ArchiveDateHint.decade(startYear: 1990).manifestDate == "1990s")
    }
}

// MARK: - Manifest CSV

@Suite("Master Archive — manifest CSV")
struct ArchiveManifestCSVTests {

    private func row(_ relPath: String, people: [String] = []) -> ArchiveManifestCSV.Row {
        ArchiveManifestCSV.Row(promotedAt: Date(timeIntervalSince1970: 0), archiveRelPath: relPath,
                               sha256: "abc", sizeBytes: 12, originalPath: "/Volumes/X/a, \"b\".mov",
                               originalVolume: "X", recordID: UUID(), sourceRecordID: UUID(),
                               recordDate: "1992-07-15", dateConfidence: "user-known",
                               people: people, starRating: 3)
    }

    @Test("every field is quoted; commas and quotes survive a round trip")
    func escapingRoundTrip() {
        let r = row("30_Video/1990-1999/1992/1992-07-15_Rick,-\"Guitar\".mov", people: ["Donna", "Rick"])
        let line = ArchiveManifestCSV.line(for: r)
        #expect(line.hasSuffix("\n"))
        #expect(line.filter { $0 == "\n" }.count == 1, "one physical line")
        let fields = ArchiveManifestCSV.fields(ofLine: line)
        #expect(fields.count == 13, "12 spec columns + readiness")
        #expect(fields[ArchiveManifestCSV.relPathColumn] == r.archiveRelPath)
        #expect(fields[4] == r.originalPath)
        #expect(fields[10] == "Donna; Rick")
        #expect(fields[ArchiveManifestCSV.sourceRecordIDColumn] == r.sourceRecordID.uuidString)
        // Bare-field check: every field starts and ends with a quote.
        let raw = line.dropLast().split(separator: ",")
        #expect(raw.first?.hasPrefix("\"") == true)
    }

    @Test("control characters and newlines are neutralized (CSV injection / line breaks)")
    func controlChars() {
        #expect(ArchiveManifestCSV.escape("a\nb\rc\u{0}d\te") == "\"a b c d e\"")
        #expect(ArchiveManifestCSV.escape("plain") == "\"plain\"")
        #expect(ArchiveManifestCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        let r = ArchiveManifestCSV.Row(promotedAt: Date(), archiveRelPath: "x\ny", sha256: "s", sizeBytes: 1,
                                       originalPath: "/p", originalVolume: "v", recordID: UUID(),
                                       sourceRecordID: UUID(), recordDate: "", dateConfidence: "",
                                       people: ["a,b"], starRating: 3)
        let line = ArchiveManifestCSV.line(for: r)
        #expect(line.filter { $0 == "\n" }.count == 1, "exactly the terminator")
    }

    @Test("append is O_APPEND (never truncates); rowsBySource reads it back")
    func appendAndReadBack() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("csv")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        let r1 = row("30_Video/Undated/xxxx-xx-xx_a.mov")
        let r2 = row("20_Audio/Undated/xxxx-xx-xx_b.wav")
        try ArchiveManifestCSV.append(r1, rootPath: sb.archiveRoot.path)
        try ArchiveManifestCSV.append(r2, rootPath: sb.archiveRoot.path)
        let text = try String(contentsOf: sb.manifestURL, encoding: .utf8)
        #expect(text.hasPrefix(MasterArchiveLayout.manifestHeader + "\n"))
        #expect(text.split(separator: "\n").count == 3)
        let rows = ArchiveManifestCSV.rowsBySource(rootPath: sb.archiveRoot.path)
        #expect(rows[r1.sourceRecordID]?.relPath == r1.archiveRelPath)
        #expect(rows[r2.sourceRecordID]?.sha256 == "abc")
        #expect(ArchiveManifestCSV.sourceRecordIDs(rootPath: sb.archiveRoot.path) == [r1.sourceRecordID, r2.sourceRecordID])
    }
}

// MARK: - Designation persistence (catalog snapshot, additive key)

@Suite("Master Archive — designation persistence")
struct MasterArchiveDesignationPersistenceTests {

    @Test("encodes only when set; legacy JSON without the key decodes nil; header probe intact")
    func snapshotRoundTrip() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601

        let bare = CatalogSnapshotDTO(version: CatalogSnapshot.currentVersion, generation: 7,
                                      savedAt: Date(), records: [], savedFromHost: "h")
        let bareData = try bare.encoded(using: enc)
        #expect(!(String(data: bareData, encoding: .utf8) ?? "").contains("masterArchive"),
                "nil designation emits NO key — byte-identity for every existing catalog")

        let d = MasterArchiveDesignation(targetPath: "/Volumes/FamilyArchive/",
                                         rootPath: "/Volumes/FamilyArchive/Breen_Family_Archive/",
                                         volumeUUID: "ABCD-1234")
        #expect(d.targetPath == "/Volumes/FamilyArchive", "canonical: no trailing slash")
        var withDesignation = bare
        withDesignation.masterArchive = d
        let data = try withDesignation.encoded(using: enc)
        let back = try dec.decode(CatalogSnapshot.self, from: data)
        #expect(back.masterArchive?.targetPath == d.targetPath && back.masterArchive?.rootPath == d.rootPath && back.masterArchive?.volumeUUID == d.volumeUUID)
        #expect(abs((back.masterArchive?.designatedAt.timeIntervalSince(d.designatedAt)) ?? 99) < 1, "ISO8601 keeps whole seconds")
        #expect(back.generation == 7)

        // Header probe still finds version/generation in the first 4 KB.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test_marchive_probe_\(UUID().uuidString.prefix(6)).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp)
        let probe = try #require(CatalogSnapshot.headerProbe(at: tmp))
        #expect(probe.generation == 7)
        #expect(probe.version == CatalogSnapshot.currentVersion)

        // Legacy: a snapshot with no masterArchive key AND no volumeUUID sub-key.
        let legacy = try dec.decode(CatalogSnapshot.self, from: bareData)
        #expect(legacy.masterArchive == nil)
        let partial = Data(#"{"version":6,"records":[],"masterArchive":{"targetPath":"/Volumes/X","rootPath":"/Volumes/X/Breen_Family_Archive","designatedAt":"2026-08-15T00:00:00Z"}}"#.utf8)
        let p = try dec.decode(CatalogSnapshot.self, from: partial)
        #expect(p.masterArchive?.volumeUUID == nil)
        #expect(p.masterArchive?.rootPath == "/Volumes/X/Breen_Family_Archive")
    }

    @Test("CatalogStore round-trips the designation through save/load in an isolated directory")
    @MainActor
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_marchive_store_\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = MasterArchiveDesignation(targetPath: dir.path, rootPath: dir.appendingPathComponent("Breen_Family_Archive").path)
        store.masterArchive = d
        #expect(store.saveNow(records: []))
        let reloaded = CatalogStore(directory: dir)
        _ = reloaded.load()
        #expect(reloaded.masterArchive?.targetPath == d.targetPath && reloaded.masterArchive?.rootPath == d.rootPath)
    }

    @Test("rehomed keeps UUID + designatedAt, recomputes root under the new mount")
    func rehome() {
        let d = MasterArchiveDesignation(targetPath: "/Volumes/Old/sub", rootPath: "/Volumes/Old/sub/Breen_Family_Archive", volumeUUID: "U")
        let r = d.rehomed(to: "/Volumes/New/sub")
        #expect(r.targetPath == "/Volumes/New/sub")
        #expect(r.rootPath == "/Volumes/New/sub/Breen_Family_Archive")
        #expect(r.volumeUUID == "U")
        #expect(r.designatedAt == d.designatedAt)
    }
}

// MARK: - Initialize + routing (model)

@Suite("Master Archive — Initialize + routing")
@MainActor
struct MasterArchiveInitializeTests {

    @Test("Initialize scaffolds the tree once, is idempotent, never truncates the manifest, adds ONE scan target with role Archive")
    func initializeIdempotent() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("init")
        defer { sb.cleanup() }
        let model = VideoScanModel()
        let before = model.scanTargets.count

        let r1 = try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(r1.addedScanTarget)
        #expect(!r1.createdPaths.isEmpty)
        let fm = FileManager.default
        for sub in ["00_Index", "10_Photos", "20_Audio", "30_Video"] {
            var isDir: ObjCBool = false
            #expect(fm.fileExists(atPath: sb.archiveRoot.appendingPathComponent(sub).path, isDirectory: &isDir) && isDir.boolValue, "\(sub)")
        }
        #expect(try String(contentsOf: sb.manifestURL, encoding: .utf8) == MasterArchiveLayout.manifestHeader + "\n")
        let readme = try String(contentsOf: MasterArchiveLayout.readmeURL(rootPath: sb.archiveRoot.path), encoding: .utf8)
        #expect(readme.contains("Breen Family Archive"))
        #expect(model.masterArchive?.rootPath == PathScope.normalize(sb.archiveRoot.standardizedFileURL.path))
        #expect(model.masterArchiveTargetID != nil)
        #expect(model.masterArchiveTarget?.role == .archive)
        #expect(model.scanTargets.count == before + 1)
        #expect(model.isMasterArchive(try #require(model.masterArchiveTarget)))

        // Append a row, hand-edit the README, then re-run Initialize.
        let row = ArchiveManifestCSV.Row(promotedAt: Date(), archiveRelPath: "30_Video/Undated/x.mov", sha256: "s",
                                         sizeBytes: 1, originalPath: "/p", originalVolume: "v", recordID: UUID(),
                                         sourceRecordID: UUID(), recordDate: "", dateConfidence: "", people: [], starRating: 3)
        try ArchiveManifestCSV.append(row, rootPath: sb.archiveRoot.path)
        try "hand edited".write(to: MasterArchiveLayout.readmeURL(rootPath: sb.archiveRoot.path), atomically: true, encoding: .utf8)

        let r2 = try MasterArchiveTestSupport.initialize(model, in: sb)
        #expect(r2.createdPaths.isEmpty, "second run creates nothing")
        #expect(!r2.addedScanTarget)
        #expect(model.scanTargets.count == before + 1, "scan target added exactly once")
        #expect(try String(contentsOf: sb.manifestURL, encoding: .utf8).split(separator: "\n").count == 2, "manifest row survived")
        #expect(try String(contentsOf: MasterArchiveLayout.readmeURL(rootPath: sb.archiveRoot.path), encoding: .utf8) == "hand edited")
    }

    @Test("Initialize refuses a retired volume (isRetired, not role) and the scratch volume")
    func initializeRefusesRetired() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("retired")
        defer { sb.cleanup() }
        let model = VideoScanModel()
        let t = CatalogScanTarget(searchPath: sb.archiveVolume.path)
        t.retiredAt = Date()
        model.scanTargets.append(t)
        #expect(throws: MasterArchiveError.self) {
            try model.initializeMasterArchive(at: sb.archiveVolume)
        }
        #expect(model.masterArchive == nil)
        #expect(!FileManager.default.fileExists(atPath: sb.archiveRoot.path), "nothing scaffolded on refusal")
        // Clearing the stamp reinstates it — `retiredAt` is the ONE owner
        // of retirement (taxonomy 2026-08-16; the `.retired` role is gone).
        t.retiredAt = nil
        #expect(throws: Never.self) { try model.initializeMasterArchive(at: sb.archiveVolume) }
        #expect(model.masterArchive != nil)
    }

    @Test("Promote without a master → the alert payload, no plan; with a master → the plan")
    func refuseWithoutMaster() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("nomaster")
        defer { sb.cleanup() }
        let model = VideoScanModel()
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("a.mov"), bytes: 1000, seed: 1)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]

        model.requestPromote(recordIDs: [rec.id])
        #expect(model.pendingPromoteWithoutMaster?.recordIDs == [rec.id])
        #expect(model.pendingPromoteRequest == nil)
        #expect(model.buildPromotePlan(recordIDs: [rec.id]) == nil)
        model.pendingPromoteWithoutMaster = nil

        try MasterArchiveTestSupport.initialize(model, in: sb)
        model.requestPromote(recordIDs: [rec.id])
        #expect(model.pendingPromoteWithoutMaster == nil)
        let plan = try #require(model.pendingPromoteRequest?.plan)
        #expect(plan.entries.count == 1)
        #expect(plan.totalBytes == 1000)
        #expect(plan.undatedCount == 1)
        #expect(plan.foldersGrouped.first?.folder == "30_Video/Undated")
    }

    @Test("clearMasterArchive forgets the designation but leaves the tree")
    func clear() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("clear")
        defer { sb.cleanup() }
        let model = VideoScanModel()
        try MasterArchiveTestSupport.initialize(model, in: sb)
        model.clearMasterArchive()
        #expect(model.masterArchive == nil)
        #expect(model.catalogStore.masterArchive == nil, "store mirror cleared too")
        #expect(FileManager.default.fileExists(atPath: sb.manifestURL.path))
    }

    @Test("import adopts a designation only when we have none")
    func importAdopts() throws {
        let model = VideoScanModel()
        let a = MasterArchiveDesignation(targetPath: "/tmp/a", rootPath: "/tmp/a/Breen_Family_Archive")
        let b = MasterArchiveDesignation(targetPath: "/tmp/b", rootPath: "/tmp/b/Breen_Family_Archive")
        model.adoptImportedMasterArchive(nil)
        #expect(model.masterArchive == nil)
        model.adoptImportedMasterArchive(a)
        #expect(model.masterArchive == a)
        model.adoptImportedMasterArchive(b)
        #expect(model.masterArchive == a, "never overwritten silently")
    }
}

// MARK: - Journey stamp

@Suite("Master Archive — journey stamp")
struct PromoteJourneyStampTests {

    @Test("'Promote <ISO>: …' parses to a .promote event and is a machine line")
    func parses() {
        let line = "Promote 2026-08-15T22:00:00Z: promoted to Master Archive as 30_Video/Undated/xxxx-xx-xx_a.mov"
        let events = VideoScanModel.parseRelocateEventsFromNotes(line)
        #expect(events.count == 1)
        #expect(events.first?.kind == .promote)
        #expect(events.first?.timestamp != nil)
        #expect(UserNotesMigration.isMachineLine(Substring(line)))
        #expect(!UserNotesMigration.isMachineLine("Promote this one later"))
    }
}

// MARK: - Reader-supplied promote dates (2026-08-31)
//
// The promote sheet asks for a date when the archive could not infer one.
// These pin the thing that actually matters — that a typed date CHANGES
// WHERE THE FILE LANDS. A green build proves only that the field exists;
// the field sat inert in UI state for a whole build before these existed.

@Suite("Archive: dates typed on the promote sheet")
struct ArchiveTypedPromoteDateTests {

    private func undatedFacts(filename: String = "UncleTerryMovie.m4v")
    -> ArchivePathResolver.RecordFacts {
        ArchivePathResolver.RecordFacts(streamType: .videoAndAudio,
                                        filename: filename, ext: "m4v",
                                        dateHint: .unknown,
                                        dateIsLowConfidence: true)
    }

    @Test("a typed year moves the file out of Undated and into its year")
    func typedYearChangesDestination() throws {
        let before = ArchivePathResolver.baseRelativePath(facts: undatedFacts())
        let hint = try #require(ArchiveDateEntry.parse("1947")?.hint)
        let after = ArchivePathResolver.baseRelativePath(
            facts: undatedFacts().withDateHint(hint))

        #expect(before != after, "typed date changed nothing: \(before)")
        #expect(before.contains("Undated"), "fixture was not undated: \(before)")
        #expect(after.contains("1940-1949/1947"), "wrong home: \(after)")
        #expect(after.contains("/1947-xx-xx_"),
                "year missing from filename, or precision invented: \(after)")
        #expect(!after.contains("Undated"), "still filed as undated: \(after)")
    }

    @Test("a typed decade files at the decade root, inventing no year")
    func typedDecadeStopsAtTheDecadeRoot() throws {
        let hint = try #require(ArchiveDateEntry.parse("1940s")?.hint)
        let path = ArchivePathResolver.baseRelativePath(
            facts: undatedFacts().withDateHint(hint))
        #expect(path.contains("1940-1949"), "not at the decade root: \(path)")
        #expect(!path.contains("1940-1949/19"), "invented a year: \(path)")
    }

    @Test("a full typed date reaches the filename to the day",
          arguments: ["July 15 1992", "July 15, 1992", "15 July 1992", "1992-07-15"])
    func typedFullDateReachesTheFilename(_ typed: String) throws {
        let hint = try #require(ArchiveDateEntry.parse(typed)?.hint,
                                "an American typing \(typed) was refused")
        let path = ArchivePathResolver.baseRelativePath(
            facts: undatedFacts().withDateHint(hint))
        #expect(path.contains("1992-07-15"), "day lost from \(typed): \(path)")
    }

    @Test("the clinical dd-mmm-yyyy form Rick types is understood",
          arguments: ["12-mar-1900", "12-MAR-1900", "12 march 1900",
                      "12.mar.1900", "12/mar/1900"])
    func clinicalDateFormIsUnderstood(_ typed: String) throws {
        let hint = try #require(ArchiveDateEntry.parse(typed)?.hint,
                                "refused the clinical form: \(typed)")
        #expect(hint == .day(year: 1900, month: 3, day: 12),
                "\(typed) parsed as \(hint)")
    }

    @Test("flattening separators does not damage the ISO numeric form")
    func isoFormSurvivesTheSeparatorRule() throws {
        let hint = try #require(ArchiveDateEntry.parse("1947-03-12")?.hint)
        #expect(hint == .day(year: 1947, month: 3, day: 12))
        let decade = try #require(ArchiveDateEntry.parse("1940s")?.hint)
        #expect(decade == .decade(startYear: 1940))
    }

    @Test("month-first order does not swallow a nonsense day")
    func americanOrderStillValidatesTheDay() {
        #expect(ArchiveDateEntry.parse("February 31 1992") == nil)
        #expect(ArchiveDateEntry.parse("Jellyfish 15 1992") == nil)
    }

    @Test("a date the reader stands behind is not marked low-confidence")
    func typedDateIsNotAGuess() throws {
        let hint = try #require(ArchiveDateEntry.parse("1947")?.hint)
        let facts = undatedFacts().withDateHint(hint)
        #expect(facts.dateIsLowConfidence == false,
                "a date the reader typed was recorded as a machine guess")
    }

    @Test("withDateHint changes the date and nothing else")
    func withDateHintIsOtherwiseTotal() throws {
        let base = undatedFacts(filename: "MaFliesToFlorida.m4v")
        let moved = base.withDateHint(.year(1947))
        #expect(moved.filename == base.filename)
        #expect(moved.ext == base.ext)
        #expect(moved.streamType == base.streamType)
    }
}


// MARK: - Routing by medium (2026-08-31)
//
// 10_Photos was declared, listed in `buckets`, created on disk by
// Initialize — and unreachable, because ffprobe reads a JPEG as a
// one-frame video. A PDF has no streams and fell into the same arm.
// Both landed in 30_Video. These pin the fix, and — more importantly —
// pin that unrecognised extensions still go where they always went.

@Suite("Archive: routing by medium")
struct ArchiveMediumRoutingTests {

    private func facts(_ stream: StreamType, _ filename: String)
    -> ArchivePathResolver.RecordFacts {
        ArchivePathResolver.RecordFacts(
            streamType: stream, filename: filename,
            ext: (filename as NSString).pathExtension,
            dateHint: .unknown, dateIsLowConfidence: false)
    }

    @Test("a loose scan reaches 10_Photos, which nothing could reach before",
          arguments: ["GrandmaScan.jpg", "letter.TIFF", "negative.dng", "x.heic"])
    func photosReachThePhotoBucket(_ name: String) {
        // ffprobe genuinely reports a still as a video stream — that is
        // why the old routing was wrong, so this passes the stream shape
        // that a real probe would have produced.
        let path = ArchivePathResolver.baseRelativePath(facts: facts(.videoOnly, name))
        #expect(path.hasPrefix("10_Photos/"), "still filed as video: \(path)")
    }

    @Test("a document reaches 50_Documents",
          arguments: ["BirthCertificate.pdf", "Letter.DOCX", "census.csv", "notes.txt"])
    func documentsReachTheDocumentBucket(_ name: String) {
        let path = ArchivePathResolver.baseRelativePath(facts: facts(.noStreams, name))
        #expect(path.hasPrefix("50_Documents/"), "document misfiled: \(path)")
    }

    @Test("audio-only still wins on a real A/V extension, as before")
    func audioIsUnaffected() {
        let path = ArchivePathResolver.baseRelativePath(facts: facts(.audioOnly, "reel.mxf"))
        #expect(path.hasPrefix("20_Audio/"), "audio regressed: \(path)")
    }

    @Test("an unknown or missing extension keeps its old home",
          arguments: ["mystery.qqq", "no_extension_at_all", "tape7.dv", ".hidden"])
    func unknownExtensionsAreUntouched(_ name: String) {
        // The safety property of this change: it can only move files it
        // positively identifies. The archive has thousands of
        // extensionless records (GH: extensionless media catalog gap) and
        // none of them may shift bucket because of this.
        let path = ArchivePathResolver.baseRelativePath(facts: facts(.videoAndAudio, name))
        #expect(path.hasPrefix("30_Video/"), "unknown file moved: \(path)")
    }

    @Test("medium is decided by extension, not by what probing claims")
    func mediumIgnoresStreamShape() {
        for stream: StreamType in [.videoAndAudio, .videoOnly, .audioOnly,
                                   .noStreams, .ffprobeFailed] {
            let path = ArchivePathResolver.baseRelativePath(facts: facts(stream, "scan.jpg"))
            #expect(path.hasPrefix("10_Photos/"),
                    "a .jpg probed as \(stream) escaped the photo bucket: \(path)")
        }
    }

    @Test("the documents bucket is one Initialize actually creates")
    func documentsBucketIsInitialized() {
        // Routing files somewhere Initialize never makes would produce a
        // promote that fails on a missing directory.
        #expect(MasterArchiveLayout.buckets.contains(MasterArchiveLayout.documentsBucket))
        #expect(MasterArchiveLayout.buckets.contains(MasterArchiveLayout.photosBucket))
    }

    @Test("dotfiles are names, not extensions")
    func dotfilesAreNotDocuments() {
        #expect(ArchiveMedium.forFilename(".DS_Store") == .audioVisual)
        #expect(ArchiveMedium.forFilename(".pdf") == .audioVisual)
        #expect(ArchiveMedium.forFilename("real.pdf") == .document)
    }
}
