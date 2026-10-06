import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateWitnessLivenessTests
//
// Pins N1007-R-MediaOps-prune-F1 (P1) and F5: Relocate's Bucket E
// ("safely redundant") must never count a dead or absent catalog row as
// the surviving copy. Bucket E marks the source record deleted and leads
// to "Retire <drive>", so a false witness means the last copy goes out
// with the retired drive.
//
// Invariant: a record is safely redundant ONLY when at least one witness
// is (a) a live catalog row (not purged, not trashed/deleted, not
// .manuallyDeleted) AND (b) present on disk now at its recorded size.
// Refuse over guess: anything else falls through to the A/C/B cascade.
//
// Fixtures are synthetic temp dirs ("test_*" names); never real media.
// Each test builds three sibling "volumes" under one temp root:
//   src/      the drive being relocated
//   witness/  a third volume holding the would-be witness
//   dest/     the destination (empty)

@MainActor
struct RelocateWitnessLivenessTests {

    private struct Fixture {
        let root: URL
        let src: URL
        let witnessVol: URL
        let dest: URL
        let srcFile: URL
        let witnessFile: URL
        let size: Int64 = 4096
        let md5 = "HASH-LIVE"

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("test_relocate_witness_\(UUID().uuidString)")
            src = root.appendingPathComponent("src")
            witnessVol = root.appendingPathComponent("witness")
            dest = root.appendingPathComponent("dest")
            for d in [src, witnessVol, dest] {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            }
            srcFile = src.appendingPathComponent("test_family.mov")
            witnessFile = witnessVol.appendingPathComponent("test_family.mov")
            try Data(repeating: 7, count: Int(size)).write(to: srcFile)
            try Data(repeating: 7, count: Int(size)).write(to: witnessFile)
        }

        func record(at url: URL) -> VideoRecord {
            let r = VideoRecord()
            r.filename = url.lastPathComponent
            r.fullPath = url.path
            r.sizeBytes = size
            r.partialMD5 = md5
            return r
        }

        func reconcile(source: VideoRecord, witness: VideoRecord) -> ReconcileResult {
            RelocateReconcile.reconcile(
                records: [source],
                allCatalogRecords: [source, witness],
                sourceVolumeRootPath: src.path,
                destinationRoot: dest,
                sourceFiles: [.init(path: srcFile.path, size: size)],
                destFiles: [],
                skipDupsOnOtherVolumes: true,
                // Sibling temp "volumes" share one disk: simulate separate
                // drives (the device rule has its own test below).
                witnessIndependent: RelocateReconcile.witnessIsNotTheSourceFile,
                hash: { [md5, srcFile, witnessFile] path in
                    (path == srcFile.path || path == witnessFile.path) ? md5 : ""
                }
            )
        }

        /// The witness row's path is an ALIAS of the source file (symlink,
        /// other case). Production probes: nothing injected.
        func reconcileWithAlias(source: VideoRecord, aliasPath: String) -> ReconcileResult {
            let witness = VideoRecord()
            witness.filename = (aliasPath as NSString).lastPathComponent
            witness.fullPath = aliasPath
            witness.sizeBytes = size
            witness.partialMD5 = md5
            return RelocateReconcile.reconcile(
                records: [source],
                allCatalogRecords: [source, witness],
                sourceVolumeRootPath: src.path,
                destinationRoot: dest,
                sourceFiles: [.init(path: srcFile.path, size: size)],
                destFiles: [],
                skipDupsOnOtherVolumes: true,
                hash: { [md5] _ in md5 }
            )
        }

        /// Apply-time proof with the inode rule only (separate drives simulated).
        var separateDrivesProof: RelocateReconcile.WitnessProof {
            .init(independent: RelocateReconcile.witnessIsNotTheSourceFile, sourceRoot: src.path)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - QA round 1 (A): the drive being retired cannot vouch for itself

    @Test func qaRedSourceFileReachedThroughASymlinkIsNotItsOwnWitness() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let link = fx.witnessVol.appendingPathComponent("test_alias.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.srcFile)
        expectMustCopy(fx.reconcileWithAlias(source: source, aliasPath: link.path), source,
                       "a symlink to the source file is the source file, not a second copy")
    }

    /// Production rule: a distinct file that lives on the SAME device as
    /// the source root is on the drive being emptied — never a witness.
    @Test func aWitnessOnTheSourceDriveIsNotIndependentEvenIfItIsAnotherFile() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        expectMustCopy(fx.reconcileWithAlias(source: source, aliasPath: fx.witnessFile.path), source,
                       "fixture witness shares the source root's device")
        #expect(!RelocateReconcile.witnessIsOffTheSourceDrive(fx.witnessFile.path, fx.srcFile.path, fx.src.path))
        #expect(RelocateReconcile.witnessIsNotTheSourceFile(fx.witnessFile.path, fx.srcFile.path, fx.src.path))
    }

    /// QA round 2: every production default is the FULL rule (device +
    /// inode). Fixture witness = a distinct file on the source's device.
    @Test func qaR2ProductionDefaults() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let w = fx.witnessFile.path, s = fx.srcFile.path, root = fx.src.path
        #expect(!VideoScanModel().relocateWitnessIndependence(w, s, root), "model default")
        #expect(!RelocateReconcile.WitnessProof(sourceRoot: root).vouches(w, sourcePath: s, bytes: fx.size),
                "WitnessProof default")
        let source = fx.record(at: fx.srcFile)
        #expect(fx.reconcileWithAlias(source: source, aliasPath: w).safelyRedundant.isEmpty, "reconcile default")
        let witness = fx.record(at: fx.witnessFile)
        let plan = RelocateReconcile.reconcilePlan(
            records: [source.asReconcileInput], witnesses: [source.asReconcileInput, witness.asReconcileInput],
            sourceVolumeRootPath: root, destinationRoot: fx.dest,
            sourceFiles: [.init(path: s, size: fx.size)], destFiles: [],
            skipDupsOnOtherVolumes: true, hash: { _ in fx.md5 })
        #expect(plan.safelyRedundant.isEmpty, "reconcilePlan default")
    }

    /// QA round 2: the weaker inode-only rule is a TEST seam. App code may
    /// never assign the model's probe, nor name the weak rule outside the
    /// file that defines it.
    @Test func appCodeNeverWeakensTheWitnessIndependenceRule() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true).resolvingSymlinksInPath()
        var offenders: [String] = []
        let it = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = it?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            for (i, line) in try String(contentsOf: url, encoding: .utf8).split(separator: "\n",
                                                                               omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                let assigns = t.contains("relocateWitnessIndependence =") && !t.hasPrefix("var relocateWitnessIndependence:")
                let weak = t.contains("witnessIsNotTheSourceFile") && name != "RelocateReconcile.swift"
                if assigns || weak { offenders.append("\(name):\(i + 1): \(t)") }
            }
        }
        #expect(offenders.isEmpty, "app code must not weaken the relocate witness rule: \(offenders)")
    }

    @Test func applyTimeReproofRefusesAWitnessThatIsTheSourceFile() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let link = fx.witnessVol.appendingPathComponent("test_alias.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.srcFile)
        let w = SafeWitnessInfo(path: link.path, role: .unassigned, trust: .unknown)
        var result = ReconcileResult(ready: [], manuallyDeleted: [], sourceSideMoves: [], adopted: [],
                                     safelyRedundant: [SafelyRedundantEntry(
                                        rec: source, witnesses: [link.path], totalWitnessCount: 1,
                                        safeWitnesses: [w], degradedWitnesses: [])],
                                     previouslyRelocated: [])
        VideoScanModel().reproveSafelyRedundantBeforeApply(&result, proof: fx.separateDrivesProof)
        #expect(result.safelyRedundant.isEmpty, "even the inode rule alone refuses a link to the source")
        #expect(result.ready.map(\.id) == [source.id])
    }

    @Test func qaRedSourceFileSpelledWithDifferentCaseIsNotItsOwnWitness() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        // <root>/SRC/test_family.mov — outside the "<root>/src/" prefix, the
        // same file on a case-insensitive volume (the APFS default).
        let upper = fx.root.appendingPathComponent("SRC").appendingPathComponent(fx.srcFile.lastPathComponent)
        try #require(FileManager.default.fileExists(atPath: upper.path),
                     "needs a case-insensitive temp volume")
        expectMustCopy(fx.reconcileWithAlias(source: source, aliasPath: upper.path), source,
                       "the source file under another case is the source file, not a second copy")
    }

    /// Expect the source record NOT to be retired as redundant; it must
    /// stay in the copy path (Bucket A, since its own file still reads).
    private func expectMustCopy(_ result: ReconcileResult, _ source: VideoRecord,
                                _ comment: Comment) {
        #expect(result.safelyRedundant.isEmpty, comment)
        #expect(result.ready.map(\.id) == [source.id], comment)
    }

    // MARK: - Positive control

    @Test func liveWitnessPresentOnDiskStillMakesTheRecordSafelyRedundant() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        let result = fx.reconcile(source: source, witness: witness)
        #expect(result.safelyRedundant.map(\.rec.id) == [source.id])
        #expect(result.safelyRedundant.first?.witnesses == [fx.witnessFile.path])
    }

    // MARK: - F1: dead catalog rows are not witnesses

    @Test func trashedWitnessRecordIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.purgedAt = Date()
        witness.lifecycleStage = .trashed
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a witness trashed by Delete Duplicates / ⌘⌫ must not vouch")
    }

    @Test func purgedButNotTrashedWitnessRecordIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.purgedAt = Date()      // Remove from Catalog
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a removed-from-catalog witness must not vouch")
    }

    @Test func permanentlyDeletedWitnessRecordIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.lifecycleStage = .deletedPermanently
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a deleted-permanently witness must not vouch")
    }

    @Test func manuallyDeletedWitnessRecordIsNotASurvivingCopy() throws {
        // Two drives vouching for each other: an earlier relocate marked
        // the witness .manuallyDeleted (itself "safely redundant").
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.archiveStage = .manuallyDeleted
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a witness an earlier relocate marked deleted must not vouch")
    }

    // MARK: - F5: the witness file must exist now, at its recorded size

    @Test func liveWitnessWhoseFileIsGoneIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        try FileManager.default.removeItem(at: fx.witnessFile)
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a stale catalog row whose file is gone must not vouch")
    }

    @Test func liveWitnessWhoseFileChangedSizeIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        try Data(repeating: 7, count: 100).write(to: fx.witnessFile)
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a witness whose file no longer matches its recorded size must not vouch")
    }

    @Test func oneDeadAndOneLiveWitnessStillVouchesWithOnlyTheLiveOne() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let live = fx.record(at: fx.witnessFile)
        let deadURL = fx.witnessVol.appendingPathComponent("test_family_copy.mov")
        try Data(repeating: 7, count: Int(fx.size)).write(to: deadURL)
        let dead = fx.record(at: deadURL)
        dead.purgedAt = Date()
        dead.lifecycleStage = .trashed
        let result = RelocateReconcile.reconcile(
            records: [source],
            allCatalogRecords: [source, dead, live],
            sourceVolumeRootPath: fx.src.path,
            destinationRoot: fx.dest,
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            witnessIndependent: RelocateReconcile.witnessIsNotTheSourceFile,
            hash: { _ in fx.md5 }
        )
        #expect(result.safelyRedundant.map(\.rec.id) == [source.id])
        #expect(result.safelyRedundant.first?.witnesses == [fx.witnessFile.path],
                "only the live, present witness may be recorded as the surviving copy")
    }

    // MARK: - Apply-time re-proof (the witness can vanish after classify)

    @Test func applyTimeReproofRefusesAnEntryWhoseWitnessVanishedSinceClassify() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        var result = fx.reconcile(source: source, witness: witness)
        #expect(result.safelyRedundant.map(\.rec.id) == [source.id], "precondition: classified E")

        // The witness drive is unplugged / the file emptied from Trash
        // between the classify pass and the apply.
        try FileManager.default.removeItem(at: fx.witnessFile)
        VideoScanModel().reproveSafelyRedundantBeforeApply(&result, proof: fx.separateDrivesProof)

        #expect(result.safelyRedundant.isEmpty, "nothing may be marked deleted without a copy on disk now")
        #expect(result.ready.map(\.id) == [source.id], "the record goes down the copy path instead")
    }

    @Test func applyTimeReproofKeepsAnEntryWhoseWitnessIsStillThere() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        var result = fx.reconcile(source: source, witness: witness)
        VideoScanModel().reproveSafelyRedundantBeforeApply(&result, proof: fx.separateDrivesProof)
        #expect(result.safelyRedundant.map(\.rec.id) == [source.id])
        #expect(result.ready.isEmpty)
    }

    @Test func reproofOrderIsStableAndUsesEachRecordsOwnSize() {
        // Pure split, injected probe: only paths in `present` exist, and
        // only at size 10.
        let present: Set<String> = ["/w/a", "/w/c"]
        let probe: WitnessPresenceProbe = { path, size in present.contains(path) && size == 10 }
        func entry(_ name: String, size: Int64) -> SafelyRedundantEntry {
            let r = VideoRecord(); r.fullPath = "/src/\(name)"; r.sizeBytes = size
            let w = SafeWitnessInfo(path: "/w/\(name)", role: .unassigned, trust: .unknown)
            return SafelyRedundantEntry(rec: r, witnesses: [w.path], totalWitnessCount: 1,
                                        safeWitnesses: [w], degradedWitnesses: [])
        }
        let entries = [entry("a", size: 10), entry("b", size: 10), entry("c", size: 10), entry("a", size: 11)]
        let split = RelocateReconcile.reproveSafelyRedundant(
            entries, proof: .init(onDisk: probe, independent: { _, _, _ in true }, sourceRoot: "/src"))
        #expect(split.proven.map(\.rec.fullPath) == ["/src/a", "/src/c"])
        #expect(split.refused.map(\.rec.fullPath) == ["/src/b", "/src/a"])
        #expect(split.refused.last?.rec.sizeBytes == 11, "a witness at another size is not this file")
    }
}
