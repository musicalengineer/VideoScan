// CorpusVerbsDriver.swift — lane `verbs` of the real-data corpus harness.
// (How this file reaches a build, the seal and the privacy rule:
// CorpusDriverSupport.swift. What the lane is for: scripts/corpus_run.py,
// "THE VERBS LANE".)
//
// The verbs that move, trash and promote, run by the app's REAL engines as
// the app calls them — on CLONES of corpus files under the run's work folder,
// never on ~/corpus/media. Nothing is re-implemented here: this file builds
// the model the way the app's own tests do (an isolated CatalogStore and
// MediaLedger under the run's scratch folder), calls each engine's entry
// point, and writes one outcome WORD per file per step.
//
//   group       Update Catalog (the real scan) over the clones, then Find
//               Duplicates (`analyzeDuplicates`): did the three byte-identical
//               clones of a `dup` file land in one group?
//   trash_copy  Move to Trash (⌘⌫: `catalogTrashPlan` + `trashSelectedRecords`)
//               on one extra clone while two other copies exist. (Through the
//               routine's file-operation seam: the row is then recorded as
//               removed outright, not as "in the Trash" — the gates are real.)
//   dedupe      Delete Duplicates (`DeleteDuplicatesJob`) over the clone volume:
//               the plan's entry status for each clone of the file.
//   trash_last  Move to Trash on the last surviving copy, confirmed WITHOUT
//               the only-copy warning (what a stale confirmation looks like):
//               the engine must hold it.
//   purge       Remove (`purgeRecords`), then a real rescan: is the row live again?
//   set_aside   Remove from Catalog (`removeFromCatalog`), then the same rescan.
//   promote     Initialize a Master Archive in the run's SCRATCH folder and
//               Promote (`PromoteToArchiveJob`, the real sound gate); the
//               archived copy is re-hashed against the file's SHA-256.
//   intact      Every clone of the file is hashed where it now is: at its path
//               (`intact`), in the run's Trash folder (`in_trash_intact`),
//               or — RED — `LOST` / `MISMATCH`.
//
// THE VERBS SEAL (on top of CorpusRun.open's; any miss is `refused`):
//   - every file, clone, the catalog and the three folders are inside this
//     run's work folder under ~/corpus/work (CorpusRun.open);
//   - the archive root is under ~/corpus/work — checked again here, by the
//     real home, immediately before the archive is initialized;
//   - THE TRASH is the run's own folder (work/<run>/trash), made new here:
//     Delete Duplicates is given it through the job's `hooks.trashItem` seam,
//     Move to Trash through the routine's `fileOperation` seam (`VerbsTrash`
//     refuses a file or a folder outside the run). The app's own Trash call is
//     never the one that runs; a test host is still required, so that if a
//     step were ever missed the file could only reach the app's test-host
//     folder — which is counted afterwards and must be empty — never the
//     Finder Trash;
//   - the scratch and archive folders are empty real folders, and every store
//     folder the driver hands a model is made by the driver, new.
//
// Privacy: outcome words are enum case names, the catalog trash plan's refusal
// raw values, the promote job's refusal codes and counts. No engine sentence
// (`note`, `detail`, a held reason) is ever written.
//
// Memory: the sample's records (tens) and one 8 MiB hashing buffer at a time.
// Disk: the promoted files are real copies in work/<run>/archive (the Python
// side caps their total); everything else is copy-on-write clones.
// (For Rick: `@MainActor func` ≈ a method that may only run on the UI thread;
// the model and its records are main-thread objects, as in the app.)

import Darwin
import Foundation
import XCTest
import VideoScanCore
@testable import VideoScan

@MainActor
final class VerbsStage {
    let run: CorpusRun
    let items: [CorpusConfig.Item]
    let vol: String
    let scratch: String
    /// The run's own Trash folder: where every engine's Trash step is pointed.
    let trash: String
    var started = Date()
    /// Files the engines reported moving to the Trash (compared with what is found there).
    var trashedByEngines = 0

    init(run: CorpusRun, vol: String, scratch: String, trash: String) {
        self.run = run
        self.items = run.config.pending
        self.vol = vol
        self.scratch = scratch
        self.trash = trash
    }

    func items(_ role: String) -> [CorpusConfig.Item] { items.filter { $0.role == role } }

    func paths(_ item: CorpusConfig.Item) -> [String] { [item.path] + (item.copies ?? []) }

    /// One step's outcome for one file. Words only (`CorpusWords.word` scrubs the rest).
    func say(_ item: CorpusConfig.Item, _ step: String, _ outcome: String, kinds: [String] = []) {
        run.progress.write(["ev": "engine", "sha": item.sha, "engine": step, "outcome": CorpusWords.word(outcome),
                            "kinds": kinds.map(CorpusWords.word), "s": Date().timeIntervalSince(started)])
    }

    func entering(_ step: String) {
        run.deadline.entering(step)
        started = Date()
    }

    static func tally(_ words: [String]) -> String {
        Dictionary(grouping: words, by: { $0 }).map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ",")
    }

    /// A model whose stores are in the run's scratch folder — each store's folder made here,
    /// new, and proven to be inside the run before the model is given it. nil = refused.
    func makeModel(_ name: String) -> VideoScanModel? {
        var folders: [URL] = []
        for kind in ["catalog-", "ledger-"] {
            let path = scratch + "/" + kind + name
            guard mkdir(path, 0o755) == 0, CorpusRun.isUnder(path, scratch), CorpusRun.isUnder(path, run.config.work) else { return nil }
            folders.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: folders[0])
        model.mediaLedger = MediaLedger(directory: folders[1])
        return model
    }

    /// A real directory (not a link to one).
    nonisolated static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// A real directory with nothing in it.
    nonisolated static func isEmptyFolder(_ path: String) -> Bool {
        isRealFolder(path) && (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true
    }

    /// Update Catalog over the clones: the production scan, waited for.
    func scan(_ model: VideoScanModel) async {
        var options = ScanOptions()
        options.skipSmallFiles = false
        options.skipChecksums = false
        model.scanOptions = options
        model.scanTargets.removeAll()
        let target = CatalogScanTarget(searchPath: vol)
        model.scanTargets.append(target)
        model.startTarget(target)
        _ = await target.scanTask?.value
    }

    func rows(_ model: VideoScanModel, at path: String) -> [VideoRecord] {
        let wanted = CorpusRun.resolved(path)
        return model.records.filter { $0.fullPath == path || CorpusRun.resolved($0.fullPath) == wanted }
    }

    func isLive(_ record: VideoRecord) -> Bool { !record.isPurged && !record.isSetAside && !record.isSuperseded }
}

/// The run's own Trash: the step every engine is given in place of the app's.
enum VerbsTrash {
    /// Moves `url` into `trash` under a new name (no clobber) and returns where it went. Refuses
    /// a file that is not inside the run, and a trash folder that is not.
    static func move(_ url: URL, into trash: String, work: String) throws -> URL {
        guard CorpusRun.isUnder(url.path, work), CorpusRun.isUnder(trash, work), VerbsStage.isRealFolder(trash) else {
            throw CorpusRefusal(word: "trash_step_outside_the_run")
        }
        let name = UUID().uuidString + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        let destination = URL(fileURLWithPath: trash, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class CorpusVerbsDriver: XCTestCase {

    @MainActor
    func testVerbsLane() async throws {
        let run: CorpusRun
        do {
            run = try CorpusRun.open(lane: "verbs")
        } catch let refusal as CorpusRefusal {
            return XCTFail("corpus harness refused: \(refusal.word)")
        }
        func refuse(_ word: String) {
            run.progress.write(["ev": "refused", "why": word])
            XCTFail("corpus harness refused: \(word)")
        }
        let config = run.config
        let workRoot = CorpusRun.realHome() + "/corpus/work"
        guard let vol = config.volRoot, let archive = config.archiveRoot, let scratch = config.scratch,
              CorpusRun.isUnder(config.work, workRoot) else { return refuse("verbs_folders_missing") }
        guard config.pending.allSatisfy({ item in ([item.path] + (item.copies ?? [])).allSatisfy { CorpusRun.isUnder($0, vol) } }) else {
            return refuse("a_verbs_file_is_not_a_clone")
        }
        // THE TRASH. Under a test host the app's one Trash call moves a file into a folder in the
        // system's per-user temporary folder — never the Finder Trash, but not inside this run
        // either (macOS gives NSTemporaryDirectory() no way to be moved: two real M4 runs were
        // refused here on 2026-11-17). So every engine is given its own injectable Trash step,
        // which moves the file into THIS run's trash folder (`VerbsTrash`), and the app's
        // test-host folder is checked afterwards to be empty. A test host is still required:
        // if a step were ever missed, the file could reach that temporary folder, not a Trash.
        guard TestEnvironment.isTestHost else { return refuse("not_a_test_host") }
        let trash = config.work + "/trash"
        guard mkdir(trash, 0o755) == 0, CorpusRun.isUnder(trash, config.work), VerbsStage.isEmptyFolder(trash) else {
            return refuse("trash_not_in_the_run")
        }
        guard CorpusRun.isUnder(archive, CorpusRun.realHome() + "/corpus/work"), CorpusRun.isUnder(archive, config.work) else {
            return refuse("archive_root_outside_corpus_work")
        }
        // The scratch and archive folders are EMPTY real folders made for this run: nothing in
        // them — a link named like a store this driver is about to make — predates it (Codex #313 F4).
        guard VerbsStage.isEmptyFolder(scratch), VerbsStage.isEmptyFolder(archive) else { return refuse("a_verbs_folder_is_not_empty") }

        let stage = VerbsStage(run: run, vol: vol, scratch: scratch, trash: trash)
        for item in stage.items { run.begin(item) }

        // The trash and catalog verbs: one model over the clones.
        guard let model = stage.makeModel("verbs") else { return refuse("a_store_folder_is_not_this_runs") }
        guard let records = try? await run.loadCatalog().records else { return XCTFail("corpus harness refused: catalog_would_not_open") }
        model.records = records
        await stage.group(model)
        await stage.trashCopy(model)
        await stage.dedupe(model)
        await stage.trashLast(model)
        await stage.removeThenRescan(model)

        // Promote: a second model, a scratch Master Archive.
        if !stage.items("promote").isEmpty {
            guard let again = try? await run.loadCatalog().records else { return XCTFail("corpus harness refused: catalog_would_not_open") }
            guard let archiveModel = stage.makeModel("promote") else { return refuse("a_store_folder_is_not_this_runs") }
            archiveModel.records = again
            await stage.promote(archiveModel, archive: archive)
        }

        let trashFiles = stage.intact()
        // The app's own test-host Trash folder (outside the run) must hold nothing: every step was given the run's.
        let stray = VerbsStage.digests(in: MediaTrash.testHostTrash.path).files
        run.progress.write(["ev": "verbs", "trashFiles": trashFiles, "trashedByEngines": stage.trashedByEngines,
                            "strayTrashFiles": stray, "records": model.records.count])
        for item in stage.items { run.end(item) }
        run.done()
    }
}

// The steps, each the engine's own entry point followed by one word per file.
extension VerbsStage {

    /// Update Catalog over the clones, then Find Duplicates.
    func group(_ model: VideoScanModel) async {
        entering("group")
        await scan(model)
        await model.analyzeDuplicates()
        for item in items("dup") {
            let found = paths(item).flatMap { rows(model, at: $0) }
            let groups = Set(found.compactMap(\.duplicateGroupID))
            let word = found.count < paths(item).count ? "rows:\(found.count)_of_\(paths(item).count)"
                : (groups.count == 1 && found.allSatisfy { $0.duplicateGroupID != nil }) ? "grouped" : "not_grouped"
            say(item, "group", word, kinds: found.map { CorpusWords.caseName($0.duplicateDisposition as Any) }.sorted())
        }
    }

    /// Move to Trash as ⌘⌫ does it: the plan, then the routine under `confirmed`, with the
    /// routine's file operation pointed at the run's Trash folder (its `fileOperation` seam —
    /// the gates, the only-copy hold and the result are the engine's; the row is then recorded
    /// as removed outright rather than as "in the Trash", which is what that seam does).
    /// Returns the word for the routine's outcome, or the plan's refusal.
    private func moveToTrash(_ model: VideoScanModel, _ row: VideoRecord, dropWarning: Bool) async -> (warned: Bool, word: String) {
        let plan = model.catalogTrashPlan(for: [row])
        if let refused = plan.refused.first { return (false, "refused:" + refused.reason.rawValue) }
        let warned = plan.onlyCopy.contains(row.id)
        var confirmed = plan
        if dropWarning { confirmed.onlyCopy = [] }               // the yes a person gave before it became the only copy
        let (trash, work) = (trash, run.config.work)
        let result = await model.trashSelectedRecords([row], confirmed: confirmed,
                                                      fileOperation: { url in _ = try VerbsTrash.move(url, into: trash, work: work) })
        let kind = result.items.first.map { CorpusWords.caseName($0.outcome.kind) } ?? "no_outcome"
        if kind == "moved" { trashedByEngines += 1 }
        return (warned, kind)
    }

    /// Move to Trash on one extra clone while two other copies exist.
    func trashCopy(_ model: VideoScanModel) async {
        entering("trash_copy")
        for item in items("dup") {
            guard let copy = item.copies?.last, let row = rows(model, at: copy).first(where: isLive) else {
                say(item, "trash_copy", "no_row")
                continue
            }
            let (warned, word) = await moveToTrash(model, row, dropWarning: false)
            say(item, "trash_copy", word.hasPrefix("refused:") ? word : (warned ? "only_copy_warned:" : "another_copy_known:") + word)
        }
    }

    /// Delete Duplicates over the clone volume: each clone's plan entry status.
    func dedupe(_ model: VideoScanModel) async {
        entering("dedupe")
        let plans = scratch + "/plans"
        guard mkdir(plans, 0o755) == 0, CorpusRun.isUnder(plans, run.config.work) else {
            for item in items("dup") { say(item, "dedupe", "refused_by_harness") }
            return
        }
        let planRoot = URL(fileURLWithPath: plans, isDirectory: true)
        var hooks = SignatureVerification.Hooks.live
        let (trash, work) = (trash, run.config.work)
        hooks.trashItem = { url in try VerbsTrash.move(url, into: trash, work: work) }     // the job's own Trash seam
        let job = DeleteDuplicatesJob(model: model, volumePath: vol, hooks: hooks, planRoot: planRoot)
        job.start()
        await job.task?.value
        for item in items("dup") {
            guard let plan = job.plan else {
                say(item, "dedupe", "no_plan")
                continue
            }
            let wanted = Set(paths(item).map(CorpusRun.resolved))
            let entries = plan.entries.filter { wanted.contains(CorpusRun.resolved($0.path)) }
            trashedByEngines += entries.filter { $0.status == .trashed }.count
            say(item, "dedupe", entries.isEmpty ? "no_entry" : VerbsStage.tally(entries.map { CorpusWords.caseName($0.status) }),
                kinds: entries.contains { $0.keeperMatchedByStoredFixity == true } ? ["keeper_matched_by_stored_fixity"] : [])
        }
    }

    /// Move to Trash on the last surviving copy, confirmed WITHOUT the only-copy warning.
    func trashLast(_ model: VideoScanModel) async {
        entering("trash_last")
        for item in items("dup") {
            let surviving = paths(item).filter { FileManager.default.fileExists(atPath: $0) }
            guard surviving.count == 1, let row = rows(model, at: surviving[0]).first(where: isLive) else {
                say(item, "trash_last", "survivors:\(surviving.count)")
                continue
            }
            let (warned, word) = await moveToTrash(model, row, dropWarning: true)
            say(item, "trash_last", word.hasPrefix("refused:") ? word : (warned ? "only_copy_warned:" : "not_warned_as_only_copy:") + word)
        }
    }

    /// Remove (purge) and Remove from Catalog (set aside), then a real rescan
    /// (the owner's doubt of 2026-11-17: does a removed or set-aside file come BACK?).
    func removeThenRescan(_ model: VideoScanModel) async {
        entering("purge")
        var before: [String: String] = [:]
        let purging = items("purge").compactMap { item in rows(model, at: item.path).first(where: isLive).map { (item, $0) } }
        model.purgeRecords(ids: Set(purging.map { $0.1.id }))
        for (item, row) in purging { before[item.sha] = row.isPurged ? "purged" : "not_purged" }
        let aside = items("set_aside").compactMap { item in rows(model, at: item.path).first(where: isLive).map { (item, $0) } }
        model.removeFromCatalog(recordIDs: aside.map { $0.1.id })
        for (item, row) in aside { before[item.sha] = row.isSetAside ? "set_aside" : row.isPurged ? "purged" : "unchanged" }
        await scan(model)
        for role in ["purge", "set_aside"] {
            for item in items(role) {
                let found = rows(model, at: item.path)
                let after = found.isEmpty ? "no_row" : found.contains(where: isLive) ? "came_back" : "stayed_removed"
                say(item, role, (before[item.sha] ?? "no_row_before") + ",rescan:" + after, kinds: ["rows:\(found.count)"])
            }
        }
    }

    /// Initialize a Master Archive in the run's scratch folder and Promote into it.
    func promote(_ model: VideoScanModel, archive: String) async {
        entering("promote")
        let promoting = items("promote")
        // Checked again here, by the real home, immediately before the archive is made.
        guard CorpusRun.isUnder(archive, CorpusRun.realHome() + "/corpus/work"), CorpusRun.isUnder(archive, run.config.work) else {
            for item in promoting { say(item, "promote", "refused_by_harness") }
            return
        }
        let root: String
        do {
            root = try model.initializeMasterArchive(at: URL(fileURLWithPath: archive, isDirectory: true)).rootPath
        } catch {
            for item in promoting { say(item, "promote", "error:" + CorpusWords.caseName(error)) }
            return
        }
        guard CorpusRun.isUnder(root, run.config.work) else {
            for item in promoting { say(item, "promote", "refused_by_harness") }
            return
        }
        let found = promoting.compactMap { item in rows(model, at: item.path).first(where: isLive).map { (item, $0) } }
        var outcomes: [PromoteToArchiveJob.FileOutcome] = []
        if let plan = model.buildPromotePlan(recordIDs: found.map { $0.1.id }) {
            let job = PromoteToArchiveJob(plan: plan, model: model)
            job.start()
            await job.task?.value
            outcomes = job.outcomes
        }
        for item in promoting {
            guard let row = found.first(where: { $0.0.sha == item.sha })?.1 else {
                say(item, "promote", "no_row")
                continue
            }
            guard let outcome = outcomes.first(where: { $0.recordID == row.id }) else {
                say(item, "promote", outcomes.isEmpty ? "no_plan" : "no_outcome")
                continue
            }
            let (word, kinds) = VerbsStage.promoteWord(outcome, sha: item.sha, root: root)
            say(item, "promote", word, kinds: kinds)
        }
        VerbsStage.unlock(under: root, inside: run.config.work)
    }

    /// The promote job's outcome as a word; a file that landed is re-hashed against its SHA-256.
    nonisolated static func promoteWord(_ outcome: PromoteToArchiveJob.FileOutcome, sha: String, root: String) -> (String, [String]) {
        var word = CorpusWords.caseName(outcome.kind) + (outcome.refusalCode.map { ":" + $0 } ?? "")
        var kinds: [String] = outcome.notLocked == nil ? [] : ["not_locked"]
        if outcome.kind == .promoted || outcome.kind == .adopted {
            let landed = URL(fileURLWithPath: root).appendingPathComponent(outcome.detail)
            let digest = CorpusRun.isUnder(landed.path, root) ? (try? CatalogStore.sha256HexStreaming(fileURL: landed)) : nil
            if digest == sha { kinds.append("archive_copy_matches") } else { word += "_MISMATCH" }
        }
        return (word, kinds)
    }

    /// Invariant: every clone is still its SHA-256, at its path or in the engines' Trash.
    /// Returns how many files the Trash holds.
    func intact() -> Int {
        entering("intact")
        let found = VerbsStage.digests(in: trash)
        var inTrash = found.digests
        for item in items {
            var words: [String] = []
            for path in paths(item) {
                if FileManager.default.fileExists(atPath: path) {
                    let digest = try? CatalogStore.sha256HexStreaming(fileURL: URL(fileURLWithPath: path))
                    words.append(digest == item.sha ? "intact" : "MISMATCH")
                } else if (inTrash[item.sha] ?? 0) > 0 {
                    inTrash[item.sha, default: 0] -= 1
                    words.append("in_trash_intact")
                } else {
                    words.append("LOST")
                }
            }
            say(item, "intact", VerbsStage.tally(words))
        }
        return found.files
    }

    /// The SHA-256 of every file under `folder` (how many of each), and the file count.
    nonisolated static func digests(in folder: String) -> (digests: [String: Int], files: Int) {
        var digests: [String: Int] = [:]
        var files = 0
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder, isDirectory: true),
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else {
            return (digests, files)
        }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files += 1
            if let digest = try? CatalogStore.sha256HexStreaming(fileURL: url) { digests[digest, default: 0] += 1 }
        }
        return (digests, files)
    }

    /// Promote locks what it archives (UF_IMMUTABLE). Cleared here, on files under the run's
    /// scratch archive only, so the run's work folder can be removed. Never on a file that
    /// has a second name (Codex #311 F3).
    nonisolated static func unlock(under root: String, inside work: String) {
        guard CorpusRun.isUnder(root, work), let walker = FileManager.default.enumerator(atPath: root) else { return }
        for case let relative as String in walker {
            let path = root + "/" + relative
            var info = stat()
            // A regular file with ONE name: a hard link could share its inode with a file outside the run.
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
               info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                _ = lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE))
            }
        }
    }
}
