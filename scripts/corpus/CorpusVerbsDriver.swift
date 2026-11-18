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
//               on one extra clone while two other copies exist.
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
//               (`intact`), in the engines' test-host Trash (`in_trash_intact`),
//               or — RED — `LOST` / `MISMATCH`.
//
// THE VERBS SEAL (on top of CorpusRun.open's; any miss is `refused`):
//   - every file, clone, the catalog and the three folders are inside this
//     run's work folder under ~/corpus/work (CorpusRun.open);
//   - the archive root is under ~/corpus/work — checked again here, by the
//     real home, immediately before the archive is initialized;
//   - the Trash the engines use is their test-host folder under this run's
//     TMPDIR (`MediaTrash.testHostTrash`), proven to be inside the work folder
//     before any verb runs. The Finder Trash is never reachable from a test host.
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
private final class VerbsStage {
    let run: CorpusRun
    let items: [CorpusConfig.Item]
    let vol: String
    let scratch: String
    var started = Date()

    init(run: CorpusRun, vol: String, scratch: String) {
        self.run = run
        self.items = run.config.pending
        self.vol = vol
        self.scratch = scratch
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

    func makeModel(_ name: String) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: URL(fileURLWithPath: scratch + "/catalog-" + name, isDirectory: true))
        model.mediaLedger = MediaLedger(directory: URL(fileURLWithPath: scratch + "/ledger-" + name, isDirectory: true))
        return model
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
        // The engines' Trash under a test host is a folder in TMPDIR: it must be this run's.
        guard TestEnvironment.isTestHost, CorpusRun.isUnder(NSTemporaryDirectory(), config.work),
              CorpusRun.isUnder(MediaTrash.testHostTrash.path, config.work) else { return refuse("trash_not_in_the_run") }
        guard CorpusRun.isUnder(archive, workRoot), CorpusRun.isUnder(archive, config.work) else {
            return refuse("archive_root_outside_corpus_work")
        }

        let stage = VerbsStage(run: run, vol: vol, scratch: scratch)
        for item in stage.items { run.begin(item) }

        // ── The trash and catalog verbs: one model over the clones ──
        let model = stage.makeModel("verbs")
        do {
            model.records = try await run.loadCatalog().records
        } catch {
            return XCTFail("corpus harness refused: catalog_would_not_open")
        }
        var trashedByEngine = 0

        stage.entering("group")
        await stage.scan(model)
        await model.analyzeDuplicates()
        for item in stage.items("dup") {
            let rows = stage.paths(item).flatMap { stage.rows(model, at: $0) }
            let groups = Set(rows.compactMap(\.duplicateGroupID))
            let word = rows.count < stage.paths(item).count ? "rows:\(rows.count)_of_\(stage.paths(item).count)"
                : (groups.count == 1 && rows.allSatisfy { $0.duplicateGroupID != nil }) ? "grouped" : "not_grouped"
            stage.say(item, "group", word, kinds: rows.map { CorpusWords.caseName($0.duplicateDisposition as Any) }.sorted())
        }

        stage.entering("trash_copy")
        for item in stage.items("dup") {
            guard let copy = item.copies?.last, let row = stage.rows(model, at: copy).first(where: stage.isLive) else {
                stage.say(item, "trash_copy", "no_row")
                continue
            }
            let plan = model.catalogTrashPlan(for: [row])
            if let refused = plan.refused.first {
                stage.say(item, "trash_copy", "refused:" + refused.reason.rawValue)
                continue
            }
            let warned = plan.onlyCopy.contains(row.id)
            let result = await model.trashSelectedRecords([row], confirmed: plan)
            let kind = result.items.first.map { CorpusWords.caseName($0.outcome.kind) } ?? "no_outcome"
            if kind == "moved" { trashedByEngine += 1 }
            stage.say(item, "trash_copy", (warned ? "only_copy_warned:" : "another_copy_known:") + kind)
        }

        stage.entering("dedupe")
        let job = DeleteDuplicatesJob(model: model, volumePath: vol, hooks: .live,
                                      planRoot: URL(fileURLWithPath: scratch + "/plans", isDirectory: true))
        job.start()
        await job.task?.value
        for item in stage.items("dup") {
            guard let plan = job.plan else {
                stage.say(item, "dedupe", "no_plan")
                continue
            }
            let wanted = Set(stage.paths(item).map(CorpusRun.resolved))
            let entries = plan.entries.filter { wanted.contains(CorpusRun.resolved($0.path)) }
            trashedByEngine += entries.filter { $0.status == .trashed }.count
            stage.say(item, "dedupe", entries.isEmpty ? "no_entry" : VerbsStage.tally(entries.map { CorpusWords.caseName($0.status) }),
                      kinds: entries.contains { $0.keeperMatchedByStoredFixity == true } ? ["keeper_matched_by_stored_fixity"] : [])
        }

        stage.entering("trash_last")
        for item in stage.items("dup") {
            let surviving = stage.paths(item).filter { FileManager.default.fileExists(atPath: $0) }
            guard surviving.count == 1, let row = stage.rows(model, at: surviving[0]).first(where: stage.isLive) else {
                stage.say(item, "trash_last", "survivors:\(surviving.count)")
                continue
            }
            let plan = model.catalogTrashPlan(for: [row])
            if let refused = plan.refused.first {
                stage.say(item, "trash_last", "refused:" + refused.reason.rawValue)
                continue
            }
            let warned = plan.onlyCopy.contains(row.id)
            var unwarned = plan                                  // the confirmation a person gave before it became the only copy
            unwarned.onlyCopy = []
            let result = await model.trashSelectedRecords([row], confirmed: unwarned)
            let kind = result.items.first.map { CorpusWords.caseName($0.outcome.kind) } ?? "no_outcome"
            if kind == "moved" { trashedByEngine += 1 }
            stage.say(item, "trash_last", (warned ? "only_copy_warned:" : "not_warned_as_only_copy:") + kind)
        }

        stage.entering("purge")
        var before: [String: String] = [:]
        let purging = stage.items("purge").compactMap { item in stage.rows(model, at: item.path).first(where: stage.isLive).map { (item, $0) } }
        model.purgeRecords(ids: Set(purging.map { $0.1.id }))
        for (item, row) in purging { before[item.sha] = row.isPurged ? "purged" : "not_purged" }
        let aside = stage.items("set_aside").compactMap { item in stage.rows(model, at: item.path).first(where: stage.isLive).map { (item, $0) } }
        model.removeFromCatalog(recordIDs: aside.map { $0.1.id })
        for (item, row) in aside { before[item.sha] = row.isSetAside ? "set_aside" : row.isPurged ? "purged" : "unchanged" }
        await stage.scan(model)                                  // the owner's doubt of 2026-11-17: does it come BACK?
        for (role, step) in [("purge", "purge"), ("set_aside", "set_aside")] {
            for item in stage.items(role) {
                let rows = stage.rows(model, at: item.path)
                let after = rows.isEmpty ? "no_row" : rows.contains(where: stage.isLive) ? "came_back" : "stayed_removed"
                stage.say(item, step, (before[item.sha] ?? "no_row_before") + ",rescan:" + after, kinds: ["rows:\(rows.count)"])
            }
        }

        // ── Promote: a second model, a scratch Master Archive ──
        stage.entering("promote")
        let promoting = stage.items("promote")
        if !promoting.isEmpty {
            let archiveModel = stage.makeModel("promote")
            guard CorpusRun.isUnder(archive, CorpusRun.realHome() + "/corpus/work"), CorpusRun.isUnder(archive, config.work),
                  let records = try? await run.loadCatalog().records else { return refuse("archive_root_outside_corpus_work") }
            archiveModel.records = records
            var root = ""
            do {
                root = try archiveModel.initializeMasterArchive(at: URL(fileURLWithPath: archive, isDirectory: true)).rootPath
            } catch {
                for item in promoting { stage.say(item, "promote", "error:" + CorpusWords.caseName(error)) }
            }
            if !root.isEmpty, CorpusRun.isUnder(root, config.work) {
                let rows = promoting.compactMap { item in stage.rows(archiveModel, at: item.path).first(where: stage.isLive).map { (item, $0) } }
                var outcomes: [PromoteToArchiveJob.FileOutcome] = []
                if let plan = archiveModel.buildPromotePlan(recordIDs: rows.map { $0.1.id }) {
                    let promote = PromoteToArchiveJob(plan: plan, model: archiveModel)
                    promote.start()
                    await promote.task?.value
                    outcomes = promote.outcomes
                }
                for item in promoting {
                    guard let row = rows.first(where: { $0.0.sha == item.sha })?.1 else {
                        stage.say(item, "promote", "no_row")
                        continue
                    }
                    guard let outcome = outcomes.first(where: { $0.recordID == row.id }) else {
                        stage.say(item, "promote", outcomes.isEmpty ? "no_plan" : "no_outcome")
                        continue
                    }
                    var word = CorpusWords.caseName(outcome.kind) + (outcome.refusalCode.map { ":" + $0 } ?? "")
                    var kinds: [String] = outcome.notLocked == nil ? [] : ["not_locked"]
                    if outcome.kind == .promoted || outcome.kind == .adopted {
                        let landed = URL(fileURLWithPath: root).appendingPathComponent(outcome.detail)
                        let digest = CorpusRun.isUnder(landed.path, root) ? (try? CatalogStore.sha256HexStreaming(fileURL: landed)) : nil
                        if digest == item.sha { kinds.append("archive_copy_matches") } else { word += "_MISMATCH" }
                    }
                    stage.say(item, "promote", word, kinds: kinds)
                }
                Self.unlock(under: root, inside: config.work)
            } else if !root.isEmpty {
                for item in promoting { stage.say(item, "promote", "refused_by_harness") }
            }
        }

        // ── Invariant: every clone is still its SHA-256, at its path or in the engines' Trash ──
        stage.entering("intact")
        var (inTrash, trashFiles) = Self.digestsInTheTrash()
        for item in stage.items {
            var words: [String] = []
            for path in stage.paths(item) {
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
            stage.say(item, "intact", VerbsStage.tally(words))
        }
        run.progress.write(["ev": "verbs", "trashFiles": trashFiles, "trashedByEngines": trashedByEngine,
                            "records": model.records.count])
        for item in stage.items { run.end(item) }
        run.done()
    }

    /// The SHA-256 of every file in the engines' test-host Trash (how many of each), and the file count.
    private static func digestsInTheTrash() -> (digests: [String: Int], files: Int) {
        var digests: [String: Int] = [:]
        var files = 0
        guard let walker = FileManager.default.enumerator(at: MediaTrash.testHostTrash, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return (digests, files)
        }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files += 1
            if let digest = try? CatalogStore.sha256HexStreaming(fileURL: url) { digests[digest, default: 0] += 1 }
        }
        return (digests, files)
    }

    /// Promote locks what it archives (UF_IMMUTABLE). Cleared here, on files under the run's
    /// scratch archive only, so the run's work folder can be removed.
    private static func unlock(under root: String, inside work: String) {
        guard CorpusRun.isUnder(root, work), let walker = FileManager.default.enumerator(atPath: root) else { return }
        for case let relative as String in walker {
            let path = root + "/" + relative
            var info = stat()
            if lstat(path, &info) == 0, info.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                _ = lchflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE))
            }
        }
    }
}
