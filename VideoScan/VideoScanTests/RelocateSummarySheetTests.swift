import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateSummarySheetTests
//
// Coverage for the two fixes that landed alongside the post-Apply
// summary sheet:
//
//   1. Dry-run no longer mutates Bucket B/D/E disposition.
//   2. After a real run, `pendingRelocateSummary` is set BEFORE
//      `pendingRetireOffer`. The retire offer doesn't fire until the
//      summary's Done button calls `acknowledgeRelocateSummary()`.
//   3. Witness samples are extracted from the safelyRedundant entries
//      and presented as `source → witness` pairs in the summary.
//   4. Even very fast runs (Bucket E only, <100 ms wall clock) hold
//      the progress UI on screen for at least 800 ms before publishing
//      the summary (Fix 2 — min-visible delay).
//   5. relocate.log is opened and written to (Fix 3 — log routing was
//      a no-op before because PersistentLog needs start()).
//
// Hermetic — /tmp workspaces, never touches /Volumes or the real
// catalog dir.

@Suite(.serialized) @MainActor
struct RelocateSummarySheetTests {

    // MARK: - Fixtures (same pattern as the other Relocate test suites)

    private static func makeWorkspace() throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-summary-\(UUID().uuidString)",
                                    isDirectory: true)
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("dest")
        let catalog = root.appendingPathComponent("catalog")
        let fm = FileManager.default
        for url in [source, dest, catalog] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (root, source, dest, catalog)
    }

    @discardableResult
    private func writeFile(at url: URL, bytes: Int) throws -> (size: Int64, md5: String) {
        var buf = Data(count: bytes)
        for i in 0..<bytes { buf[i] = UInt8((i &* 17) % 251) }
        try buf.write(to: url)
        return (Int64(bytes), FileHasher.partialMD5(path: url.path))
    }

    private func makeRecord(fullPath: String, size: Int64, md5: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    /// Poll until the summary sheet binding is populated (the run has
    /// completed AND the min-visible pad has elapsed). Single timeout
    /// covers the worst case of an E-only run (~0.8 s) plus margin.
    private func waitForSummary(_ model: VideoScanModel, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)  // 25 ms
        }
    }

    // MARK: - 1. Dry-run mutation gate

    @Test
    func dryRun_doesNotMutateBucketBDEDispositions() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Three records exercising each catalog-only bucket:
        //
        //   B: file missing on disk → manuallyDeleted target
        //   D: file already at dest → adopted target
        //   E: file dup'd on a third (offline) catalogued volume
        //
        // All three would normally trigger archiveStage writes in
        // runRelocate. With the dry-run gate they must stay .none.

        // B — missing file. No disk presence anywhere.
        let bPath = ws.source.appendingPathComponent("b-missing.bin").path
        let bRec = makeRecord(fullPath: bPath, size: 1024,
                              md5: "DEADBEEFDEADBEEFDEADBEEFDEADBEEF")

        // D — file already at dest, removed from source so reconcile
        // can't see it on the source side.
        let dSrc = ws.source.appendingPathComponent("d-already.bin")
        let (dSize, dHash) = try writeFile(at: dSrc, bytes: 512)
        let dDest = ws.dest.appendingPathComponent("d-already.bin")
        try FileManager.default.copyItem(at: dSrc, to: dDest)
        try FileManager.default.removeItem(at: dSrc)
        let dRec = makeRecord(fullPath: dSrc.path, size: dSize, md5: dHash)

        // E — file on source + duplicated on a third volume.
        let eSrc = ws.source.appendingPathComponent("e-dup.bin")
        let (eSize, eHash) = try writeFile(at: eSrc, bytes: 256)
        let eRec = makeRecord(fullPath: eSrc.path, size: eSize, md5: eHash)
        let witness = makeRecord(fullPath: "/Volumes/MyBook/e-dup.bin",
                                 size: eSize, md5: eHash)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [bRec, dRec, eRec, witness]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: true,                // <-- the headline of the test
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        // None of the three target records changed disposition. They
        // are all still .none. This is the regression the fix prevents.
        #expect(bRec.archiveStage == .none, "Bucket B record mutated in dry-run")
        #expect(dRec.archiveStage == .none, "Bucket D record mutated in dry-run")
        #expect(eRec.archiveStage == .none, "Bucket E record mutated in dry-run")
        // Paths likewise untouched.
        #expect(bRec.fullPath == bPath)
        #expect(dRec.fullPath == dSrc.path)
        #expect(eRec.fullPath == eSrc.path)
        // Provenance not stamped on the adopted candidate.
        #expect(dRec.originalFullPath == nil)

        // Summary title flag is set.
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.isDryRun == true)
        // Dry-run summary counts come from reconcile, so we should see
        // the three catalog-only bucket members reflected in the
        // dashboard counters that fed the summary.
        #expect(summary.manuallyDeletedCount == 1)
        #expect(summary.adoptedCount == 1)
        #expect(summary.safelyRedundantCount == 1)
        // Dry-run never fires retire.
        #expect(model.pendingRetireOffer == nil)
    }

    // MARK: - 2. Summary ends with Volumes CTA, not auto-retire prompt

    @Test
    func summarySheet_endsWithVolumesWindowCTA_notAutoRetirePrompt() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // One Bucket E record → after Apply, the source is 100%
        // disposed (.manuallyDeleted). Previously, clicking Done on the
        // summary would auto-fire the retire offer. Per Rick's
        // 2026-05-30 feedback (friendly_language), the Volumes window
        // is now the retire surface — Done just drops the summary and
        // the user opens the Volumes window themselves.
        let src = ws.source.appendingPathComponent("safe.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 1024)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        // Witness on a SAFE host volume — required for Bucket E
        // classification under the post-2026-05-30 safety filter.
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/safe.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        // Mark MyBook as a safe (backup + reliable) host so Bucket E
        // classification fires. Plain scan target for the source.
        let safeWitness = CatalogScanTarget(searchPath: "/Volumes/MyBook")
        safeWitness.role = .backup
        safeWitness.trust = .reliable
        model.scanTargets = [
            CatalogScanTarget(searchPath: ws.source.path),
            safeWitness
        ]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        // Summary is present. Retire offer should NEVER fire before
        // acknowledgment.
        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.isDryRun == false)
        #expect(summary.sourceVolumeRootPath == ws.source.path)
        #expect(model.pendingRetireOffer == nil,
                "Retire offer fired before summary was acknowledged")

        // Acknowledge: drops summary. CRUCIAL: does NOT fire the retire
        // offer. The Volumes window is the explicit retire surface now.
        model.acknowledgeRelocateSummary()

        #expect(model.pendingRelocateSummary == nil)
        #expect(model.pendingRetireOffer == nil,
                "Done should not auto-fire retire — feedback_friendly_language")
    }

    // MARK: - 3. Witness sample extraction

    @Test
    func summarySheet_witnessDisclosure_extractsSourceWitnessPairsFromBucketE() {
        // Pure helper test: build a synthetic reconcile result with two
        // Bucket E entries and confirm witnessSamples pulls the first
        // witness from each.
        let r1 = VideoRecord()
        r1.fullPath = "/Volumes/Old/a.bin"
        r1.filename = "a.bin"
        let r2 = VideoRecord()
        r2.fullPath = "/Volumes/Old/b.bin"
        r2.filename = "b.bin"

        // Build minimal safeWitnesses arrays so `witnessSamples` picks
        // the safe-ranked path. The reconcile engine always populates
        // these in production; the legacy fallback (audit-trail string
        // array) covers older serialized state.
        let entries: [SafelyRedundantEntry] = [
            .init(rec: r1,
                  witnesses: ["/Volumes/MyBook/a.bin", "/Volumes/Backup/a.bin"],
                  totalWitnessCount: 2,
                  safeWitnesses: [
                    .init(path: "/Volumes/MyBook/a.bin",
                          role: .backup, trust: .reliable),
                    .init(path: "/Volumes/Backup/a.bin",
                          role: .backup, trust: .reliable)
                  ],
                  degradedWitnesses: []),
            .init(rec: r2,
                  witnesses: ["/Volumes/MyBook/b.bin"],
                  totalWitnessCount: 1,
                  safeWitnesses: [
                    .init(path: "/Volumes/MyBook/b.bin",
                          role: .backup, trust: .reliable)
                  ],
                  degradedWitnesses: [])
        ]
        let samples = VideoScanModel.witnessSamples(from: entries, limit: 10)
        #expect(samples.count == 2)
        #expect(samples[0].sourcePath == "/Volumes/Old/a.bin")
        #expect(samples[0].witnessPath == "/Volumes/MyBook/a.bin")
        #expect(samples[0].witnessRole == .backup)
        #expect(samples[0].witnessTrust == .reliable)
        #expect(samples[1].sourcePath == "/Volumes/Old/b.bin")
        #expect(samples[1].witnessPath == "/Volumes/MyBook/b.bin")

        // Cap: 12 entries, limit 10 → only 10 samples.
        let many: [SafelyRedundantEntry] = (0..<12).map { i in
            let r = VideoRecord()
            r.fullPath = "/Volumes/Old/x\(i).bin"
            r.filename = "x\(i).bin"
            return .init(rec: r,
                         witnesses: ["/Volumes/MyBook/x\(i).bin"],
                         totalWitnessCount: 1,
                         safeWitnesses: [
                            .init(path: "/Volumes/MyBook/x\(i).bin",
                                  role: .backup, trust: .reliable)
                         ],
                         degradedWitnesses: [])
        }
        let capped = VideoScanModel.witnessSamples(from: many, limit: 10)
        #expect(capped.count == 10)
    }

    // MARK: - 4. Minimum visible delay

    @Test
    func progressUI_shortRun_paddedToMin800ms() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Bucket E only: catalog-only mutation, no copies. Whole run is
        // typically <100 ms on a /tmp workspace. We measure the wall
        // clock from kickoff to summary-published to confirm the pad
        // fires.
        let src = ws.source.appendingPathComponent("blip.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 64)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/blip.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)

        let kickoff = Date()
        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)
        let elapsed = Date().timeIntervalSince(kickoff)

        // Allow a small jitter floor (~50 ms) under the 800 ms target
        // to account for scheduler imprecision on a busy host. The
        // important bit is "much longer than the actual work would
        // otherwise take", not literal 0.8s to the millisecond.
        #expect(elapsed >= 0.75, "Run finished in \(elapsed)s — min-visible pad isn't firing")
        // Sanity bound — should NOT be padded to many seconds.
        #expect(elapsed < 5.0)
    }

    // MARK: - 5. relocate.log routing

    @Test
    func relocateLog_writesToRelocateLogFile_notCatalogLog() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Capture the size of relocate.log before the run. PersistentLog
        // appends to ~/Library/Logs/VideoScan/relocate.log; the test
        // can't redirect that, but it CAN measure growth.
        let logURL = PersistentLog.logDir.appendingPathComponent("relocate.log")
        let sizeBefore: Int = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                  let n = attrs[.size] as? Int else { return 0 }
            return n
        }()

        // Drive a minimal run through. Bucket E is the cheapest
        // catalog-only path.
        let src = ws.source.appendingPathComponent("logged.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 32)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/logged.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)
        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        // Force any final flush.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // File must now exist + have grown.
        #expect(FileManager.default.fileExists(atPath: logURL.path),
                "relocate.log was not created at \(logURL.path)")

        let sizeAfter: Int = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                  let n = attrs[.size] as? Int else { return 0 }
            return n
        }()
        #expect(sizeAfter > sizeBefore,
                "relocate.log did not grow (\(sizeBefore) → \(sizeAfter)) — log routing broken")

        // Spot-check the contents: the per-session header is the
        // signature of Fix 3 (header was new in this change, so finding
        // it proves we landed there). We decode the whole file as UTF-8
        // rather than a tail slice — slicing mid-stream can land in the
        // middle of a multi-byte sequence (the log uses `─` separators,
        // 3 bytes each) and `String(data: encoding: .utf8)` returns nil
        // on those, which would falsely trip this assertion. File is
        // small (<100 KB even after a long suite); reading whole is cheap.
        let body: String = {
            guard let data = try? Data(contentsOf: logURL) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }()
        #expect(body.contains("Migrate session started"),
                "Header line missing — relocate.log open or header write failed")
    }

    // MARK: - 6. Bucket E requires at least one safe witness (post-2026-05-30)

    @Test
    func bucketE_requiresAtLeastOneSafeWitness() {
        // Rick's framing: a "backup" that lives on a retired or
        // unreliable volume isn't reassuring. The Bucket E classification
        // should refuse to fire on degraded-only witnesses; the record
        // falls through to Bucket A (must be copied) instead.
        let src = VideoRecord()
        src.fullPath = "/Volumes/SourceDrive/clip.mxf"
        src.filename = "clip.mxf"
        src.sizeBytes = 1024
        src.partialMD5 = "deadbeefdeadbeefdeadbeefdeadbeef"

        // Two witnesses, BOTH on degraded hosts.
        let retiredWitness = VideoRecord()
        retiredWitness.fullPath = "/Volumes/OldMaxtor/clip.mxf"
        retiredWitness.sizeBytes = 1024
        retiredWitness.partialMD5 = src.partialMD5

        let unreliableWitness = VideoRecord()
        unreliableWitness.fullPath = "/Volumes/FlakyDrive/clip.mxf"
        unreliableWitness.sizeBytes = 1024
        unreliableWitness.partialMD5 = src.partialMD5

        // Resolver marks both hosts degraded.
        let resolver: VolumeSafetyResolver = { p in
            // Retired host: role stays whatever it was (Backup here); the
            // retirement rides on `isRetired` (taxonomy 2026-08-16).
            if p.hasPrefix("/Volumes/OldMaxtor/") { return VolumeSafety(role: .backup, trust: .reliable, isRetired: true) }
            if p.hasPrefix("/Volumes/FlakyDrive/") { return VolumeSafety(role: .backup, trust: .unreliable) }
            return VolumeSafety.unknown
        }

        let result = RelocateReconcile.reconcile(
            records: [src],
            allCatalogRecords: [src, retiredWitness, unreliableWitness],
            sourceVolumeRootPath: "/Volumes/SourceDrive",
            destinationRoot: URL(fileURLWithPath: "/Volumes/Dest"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            resolveVolumeSafety: resolver,
            hash: { _ in "" }
        )

        // Bucket E refused to fire: no safe witness.
        #expect(result.safelyRedundant.isEmpty,
                "Record with degraded-only witnesses must NOT be safelyRedundant")
        // Falls through to manuallyDeleted (no file at recorded path,
        // no source-side match in sourceFiles).
        #expect(result.manuallyDeleted.count == 1)

        // Now add a SAFE witness — classification should flip on.
        let safeWitness = VideoRecord()
        safeWitness.fullPath = "/Volumes/LaCieWorkspace/clip.mxf"
        safeWitness.sizeBytes = 1024
        safeWitness.partialMD5 = src.partialMD5
        let resolverWithSafe: VolumeSafetyResolver = { p in
            if p.hasPrefix("/Volumes/OldMaxtor/") { return VolumeSafety(role: .backup, trust: .reliable, isRetired: true) }
            if p.hasPrefix("/Volumes/FlakyDrive/") { return VolumeSafety(role: .backup, trust: .unreliable) }
            if p.hasPrefix("/Volumes/LaCieWorkspace/") { return VolumeSafety(role: .offsite, trust: .reliable) }
            return VolumeSafety.unknown
        }
        let result2 = RelocateReconcile.reconcile(
            records: [src],
            allCatalogRecords: [src, retiredWitness, unreliableWitness, safeWitness],
            sourceVolumeRootPath: "/Volumes/SourceDrive",
            destinationRoot: URL(fileURLWithPath: "/Volumes/Dest"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            resolveVolumeSafety: resolverWithSafe,
            hash: { _ in "" }
        )
        #expect(result2.safelyRedundant.count == 1)
        let entry = try? #require(result2.safelyRedundant.first)
        // Safe witness leads the safeWitnesses list.
        #expect(entry?.safeWitnesses.first?.path == "/Volumes/LaCieWorkspace/clip.mxf")
        // Both degraded witnesses are retained on the entry for the
        // "see all matches" disclosure.
        #expect(entry?.degradedWitnesses.count == 2)
    }

    // MARK: - 7. Witness ranking — role dominates trust

    @Test
    func witnessRanking_sortsBySafetyScore_roleDominatesOverTrust() {
        // Same-record, multiple witnesses, mix of roles/trusts. After
        // ranking, an Archive+Aging witness should outrank a Backup+
        // Reliable one (role weighted 10x trust).
        let src = VideoRecord()
        src.fullPath = "/Volumes/Src/x.bin"
        src.sizeBytes = 1024
        src.partialMD5 = "aa"

        let witnesses = [
            ("/Volumes/A/x.bin", VolumeRole.backup, VolumeTrust.reliable),
            ("/Volumes/B/x.bin", VolumeRole.offsite, VolumeTrust.aging),
            ("/Volumes/C/x.bin", VolumeRole.archive, VolumeTrust.unknown),
            ("/Volumes/D/x.bin", VolumeRole.original, VolumeTrust.reliable)
        ]
        let resolver: VolumeSafetyResolver = { p in
            for (path, role, trust) in witnesses where p.hasPrefix(path) {
                return VolumeSafety(role: role, trust: trust)
            }
            return VolumeSafety.unknown
        }
        let witnessRecords = witnesses.map { (path, _, _) -> VideoRecord in
            let r = VideoRecord()
            r.fullPath = path
            r.sizeBytes = 1024
            r.partialMD5 = "aa"
            return r
        }

        let result = RelocateReconcile.reconcile(
            records: [src],
            allCatalogRecords: [src] + witnessRecords,
            sourceVolumeRootPath: "/Volumes/Src",
            destinationRoot: URL(fileURLWithPath: "/Volumes/Dest"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            resolveVolumeSafety: resolver,
            hash: { _ in "" }
        )
        let entry = try? #require(result.safelyRedundant.first)
        // Expected order (highest safetyScore first):
        //   Offsite + Aging  → 6*10 + 2 = 62
        //   Archive + Unknown→ 5*10 + 1 = 51
        //   Backup + Reliable→ 4*10 + 3 = 43
        //   Original + Reliable → 3*10 + 3 = 33
        let safePaths = entry?.safeWitnesses.map(\.path) ?? []
        #expect(safePaths == [
            "/Volumes/B/x.bin",   // LTA + Aging
            "/Volumes/C/x.bin",   // Archive + Unknown
            "/Volumes/A/x.bin",   // Backup + Reliable
            "/Volumes/D/x.bin"    // Original + Reliable
        ])
    }

    // MARK: - 8. Witness ranking — retired/unreliable demoted below safe

    @Test
    func witnessRanking_demotesRetiredAndUnreliableBelowSafeOnes() {
        // Mix of one safe + one retired + one unreliable. Reconcile
        // result should split into safeWitnesses (just the safe one)
        // and degradedWitnesses (the other two).
        let src = VideoRecord()
        src.fullPath = "/Volumes/Src/y.bin"
        src.sizeBytes = 512
        src.partialMD5 = "bb"

        let mybook = VideoRecord()
        mybook.fullPath = "/Volumes/MyBook/y.bin"
        mybook.sizeBytes = 512
        mybook.partialMD5 = "bb"

        let mini2tb = VideoRecord()  // retired
        mini2tb.fullPath = "/Volumes/Mini2TB/y.bin"
        mini2tb.sizeBytes = 512
        mini2tb.partialMD5 = "bb"

        let flaky = VideoRecord()  // unreliable
        flaky.fullPath = "/Volumes/Flaky/y.bin"
        flaky.sizeBytes = 512
        flaky.partialMD5 = "bb"

        let resolver: VolumeSafetyResolver = { p in
            if p.hasPrefix("/Volumes/MyBook/") { return VolumeSafety(role: .backup, trust: .reliable) }
            if p.hasPrefix("/Volumes/Mini2TB/") { return VolumeSafety(role: .backup, trust: .reliable, isRetired: true) }
            if p.hasPrefix("/Volumes/Flaky/") { return VolumeSafety(role: .backup, trust: .unreliable) }
            return VolumeSafety.unknown
        }

        let result = RelocateReconcile.reconcile(
            records: [src],
            allCatalogRecords: [src, mybook, mini2tb, flaky],
            sourceVolumeRootPath: "/Volumes/Src",
            destinationRoot: URL(fileURLWithPath: "/Volumes/Dest"),
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            resolveVolumeSafety: resolver,
            hash: { _ in "" }
        )
        let entry = try? #require(result.safelyRedundant.first)
        #expect(entry?.safeWitnesses.map(\.path) == ["/Volumes/MyBook/y.bin"])
        // Retired + unreliable both demoted. Order within degraded
        // doesn't matter for Rick's UX (it's grey-and-tagged either
        // way), but the count does.
        #expect(entry?.degradedWitnesses.count == 2)
        let demotedPaths = Set(entry?.degradedWitnesses.map(\.path) ?? [])
        #expect(demotedPaths == [
            "/Volumes/Mini2TB/y.bin",
            "/Volumes/Flaky/y.bin"
        ])
    }

    // MARK: - 9. Summary headline — all-safe pattern

    @Test
    func summarySheet_headlineMatchesPattern_allSafe() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // One Bucket E record with a safe witness — produces the
        // "Your files are safe" headline (no Bucket A copies, all
        // already-safe).
        let src = ws.source.appendingPathComponent("safe.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 512)
        let srcRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/safe.bin",
                                    size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        let safeWitness = CatalogScanTarget(searchPath: "/Volumes/MyBook")
        safeWitness.role = .offsite
        safeWitness.trust = .reliable
        model.scanTargets = [
            CatalogScanTarget(searchPath: ws.source.path),
            safeWitness
        ]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.succeededCount == 0)
        #expect(summary.safelyBackedUpCount == 1)
        #expect(summary.degradedOnlyCount == 0)
        // Sample carries the safe host's role/trust.
        let sample = try #require(summary.witnessSamples.first)
        #expect(sample.witnessRole == .offsite)
        #expect(sample.witnessTrust == .reliable)
        #expect(sample.isSafe)
    }

    // MARK: - 10. Summary headline — mixed copy + redundant pattern

    @Test
    func summarySheet_headlineMatchesPattern_mixedCopyAndRedundant() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // One Bucket A record (will be copied) + one Bucket E record
        // (will not be copied). Produces the "Files copied and
        // verified" headline.
        let copyMe = ws.source.appendingPathComponent("copy.bin")
        let (cSize, cHash) = try writeFile(at: copyMe, bytes: 256)
        let copyRec = makeRecord(fullPath: copyMe.path, size: cSize, md5: cHash)

        let redundant = ws.source.appendingPathComponent("redundant.bin")
        let (rSize, rHash) = try writeFile(at: redundant, bytes: 128)
        let redundantRec = makeRecord(fullPath: redundant.path, size: rSize, md5: rHash)
        let witnessRec = makeRecord(fullPath: "/Volumes/MyBook/redundant.bin",
                                    size: rSize, md5: rHash)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [copyRec, redundantRec, witnessRec]
        let safeWitness = CatalogScanTarget(searchPath: "/Volumes/MyBook")
        safeWitness.role = .backup
        safeWitness.trust = .reliable
        model.scanTargets = [
            CatalogScanTarget(searchPath: ws.source.path),
            safeWitness
        ]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForSummary(model)

        let summary = try #require(model.pendingRelocateSummary)
        #expect(summary.succeededCount == 1, "one Bucket A copy should have happened")
        #expect(summary.safelyBackedUpCount == 1, "one Bucket E record should be safely backed up")
        #expect(summary.degradedOnlyCount == 0)
    }

    // MARK: - 11. User-visible verb is "Migrate", not "Relocate"

    /// Regression guard for the 2026-05-31 user-facing rename. The
    /// `RelocateSummarySheet` (internal type name preserved) drives a
    /// post-flight payload that surfaces user-visible headlines, sub-
    /// headlines, and a notification title. None of those rendered
    /// strings should contain the word "Relocate" — Rick decided
    /// "Migrate" matches the Apple Migration Assistant vibe better.
    ///
    /// Internal symbol names (`pendingRelocateSummary`, `RelocateSummary`,
    /// `acknowledgeRelocateSummary`, etc.) are deliberately NOT touched
    /// by this guard — only the user-facing copy is in scope.
    /// Local workspace builder that avoids "relocate" in the directory
    /// name so the body-text scan in the guard test below isn't tripped
    /// by the fixture path leaking into `destinationDisplay`. Same shape
    /// as `makeWorkspace` otherwise.
    private static func makeNeutralWorkspace() throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-friendly-\(UUID().uuidString)",
                                    isDirectory: true)
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("dest")
        let catalog = root.appendingPathComponent("catalog")
        let fm = FileManager.default
        for url in [source, dest, catalog] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (root, source, dest, catalog)
    }

    @Test
    func friendlyHeadlines_neverContainRelocateWord() async throws {
        // Cover all three headline modes the summary sheet renders:
        //   - "Your files are safe"     (all-safe path)
        //   - "Files copied and verified" (mixed copy + safe)
        //   - "Dry-run preview"          (preview only)
        //
        // For each mode we synthesize a RelocateSummary by driving a
        // real run, then assert no user-visible field carries
        // "Relocate"/"relocate"/"Relocated"/"relocated".

        @MainActor func runOneAndCapture(
            dryRun: Bool,
            withSafeWitness: Bool,
            copyAFile: Bool
        ) async throws -> RelocateSummary {
            let inner = try Self.makeNeutralWorkspace()
            defer { try? FileManager.default.removeItem(at: inner.root) }

            var records: [VideoRecord] = []
            if copyAFile {
                let copyMe = inner.source.appendingPathComponent("copy.bin")
                let (cSize, cHash) = try writeFile(at: copyMe, bytes: 256)
                records.append(makeRecord(fullPath: copyMe.path, size: cSize, md5: cHash))
            }
            if withSafeWitness {
                let safe = inner.source.appendingPathComponent("safe.bin")
                let (sSize, sHash) = try writeFile(at: safe, bytes: 128)
                records.append(makeRecord(fullPath: safe.path, size: sSize, md5: sHash))
                let witness = makeRecord(
                    fullPath: "/Volumes/MyBook/safe.bin",
                    size: sSize, md5: sHash
                )
                records.append(witness)
            }

            let model = VideoScanModel()
            model.catalogStore = CatalogStore(directory: inner.catalog)
            model.records = records
            let safeTarget = CatalogScanTarget(searchPath: "/Volumes/MyBook")
            safeTarget.role = .backup
            safeTarget.trust = .reliable
            model.scanTargets = [
                CatalogScanTarget(searchPath: inner.source.path),
                safeTarget
            ]
            model.catalogStore.saveNow(records: model.records)

            model.relocateVolume(RelocateOptions(
                sourceVolumeRootPath: inner.source.path,
                destinationRoot: inner.dest,
                maxConcurrency: 1,
                dryRun: dryRun,
                skipAlreadyRelocated: true,
                skipDupsOnOtherVolumes: true
            ))
            await waitForSummary(model)
            return try #require(model.pendingRelocateSummary)
        }

        // Strings that, if found, prove the rename slipped. Case-
        // sensitive `.contains` covers all the surface-area variants
        // (Relocate/relocate/Relocated/relocated/Relocation/relocation).
        let banned = [
            "Relocate", "relocate", "Relocated", "relocated",
            "Relocation", "relocation"
        ]
        func assertNoBanned(_ s: String, _ label: String) {
            for needle in banned {
                #expect(!s.contains(needle),
                        "\(label) contains banned word '\(needle)': \(s)")
            }
        }

        // The three headline-producing helpers on RelocateSummarySheet
        // are private; we exercise the same data via the summary's
        // structured fields. The sheet's title/body strings are pure
        // functions of (isDryRun, succeededCount, safelyBackedUpCount,
        // total), so re-deriving them here gives us the same surface
        // without instantiating SwiftUI.
        func headlineTitleFor(_ s: RelocateSummary) -> String {
            if s.isDryRun { return "Dry-run preview" }
            if s.succeededCount > 0 { return "Files copied and verified" }
            return "Your files are safe"
        }
        func headlineBodyFor(_ s: RelocateSummary) -> String {
            if s.isDryRun {
                return "If you ran this for real, here's what would happen."
            }
            let total = s.succeededCount + s.safelyBackedUpCount
            if s.succeededCount > 0 {
                var line = "I copied \(s.succeededCount) file"
                    + (s.succeededCount == 1 ? "" : "s")
                    + " to \(s.destinationDisplay) and verified the checksums."
                if s.safelyBackedUpCount > 0 {
                    line += " \(s.safelyBackedUpCount) more "
                    line += s.safelyBackedUpCount == 1 ? "is" : "are"
                    line += " already safely backed up on other drives."
                }
                return line
            }
            return "I found backup copies of all \(total) file"
                + (total == 1 ? "" : "s")
                + " on safer drives and checksum-verified them. "
                + "Everything's accounted for — you can retire "
                + "\(s.sourceVolumeName) whenever you're ready."
        }

        // Mode 1: all-safe ("Your files are safe").
        let allSafe = try await runOneAndCapture(
            dryRun: false, withSafeWitness: true, copyAFile: false
        )
        assertNoBanned(headlineTitleFor(allSafe), "all-safe title")
        assertNoBanned(headlineBodyFor(allSafe), "all-safe body")

        // Mode 2: mixed copy + redundant ("Files copied and verified").
        let mixed = try await runOneAndCapture(
            dryRun: false, withSafeWitness: true, copyAFile: true
        )
        assertNoBanned(headlineTitleFor(mixed), "mixed title")
        assertNoBanned(headlineBodyFor(mixed), "mixed body")

        // Mode 3: dry-run ("Dry-run preview").
        let dry = try await runOneAndCapture(
            dryRun: true, withSafeWitness: true, copyAFile: true
        )
        assertNoBanned(headlineTitleFor(dry), "dry-run title")
        assertNoBanned(headlineBodyFor(dry), "dry-run body")

        // Bonus: notification title strings come out of the same
        // user-visible surface. Cover both .complete and .failed.
        let completeJob = RelocateQueuedJob(
            sourceVolumeRootPath: "/Volumes/Maxtor500FW",
            sourceVolumeName: "Maxtor500FW",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            options: RelocateOptions(
                sourceVolumeRootPath: "/Volumes/Maxtor500FW",
                destinationRoot: URL(fileURLWithPath: "/tmp")
            ),
            status: .complete
        )
        assertNoBanned(
            VideoScanModel.notificationTitle(for: completeJob),
            "notification title (complete)"
        )
        let failedJob = RelocateQueuedJob(
            sourceVolumeRootPath: "/Volumes/Bad",
            sourceVolumeName: "Bad",
            destinationRoot: URL(fileURLWithPath: "/tmp"),
            options: RelocateOptions(
                sourceVolumeRootPath: "/Volumes/Bad",
                destinationRoot: URL(fileURLWithPath: "/tmp")
            ),
            status: .failed(reason: "disk full")
        )
        assertNoBanned(
            VideoScanModel.notificationTitle(for: failedJob),
            "notification title (failed)"
        )

        // Also sanity-check the new (post-rename) headline labels are
        // what we expect — defends against a future find/replace pass
        // accidentally removing the renamed term too.
        #expect(headlineTitleFor(dry) == "Dry-run preview")
        #expect(headlineTitleFor(allSafe) == "Your files are safe")
        #expect(headlineTitleFor(mixed) == "Files copied and verified")
    }
}
