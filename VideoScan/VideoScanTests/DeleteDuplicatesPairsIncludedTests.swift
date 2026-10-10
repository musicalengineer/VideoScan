// DeleteDuplicatesPairsIncludedTests.swift
// Rick's ruling, 2026-10-09 evening (design §9 R5, revised): "why do I need
// to checkbox every file, how am I supposed to know it is safe to delete —
// when I select delete dups it should do what it said, ensure it is only
// deleting extras." A bulk Delete Duplicates run keeps ONE proven copy and
// moves EVERY proven extra — pairs included. No per-file tick, no "not
// pre-selected" hold, fresh or resumed. The safety is the proof at the move
// (keeper read in full / digest-matched + identity, online, not an alias of
// the target); anything unprovable is held with its reason.
//
// This supersedes codex delete-engines F6 ("resumed legacy bulk plans skip
// the 2-copy explicit-pick rule"): there is no pick rule to skip — fresh and
// resumed plans follow the same rule, both through full proof at the move.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Delete Duplicates — a bulk run moves every proven extra, pairs included (R5 revised)", .serialized)
@MainActor
struct DeleteDuplicatesPairsIncludedTests {

    private struct Pair {
        let dir: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copy: VideoRecord
        var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
        var root: URL { dir.appendingPathComponent("plans", isDirectory: true) }
        var trashed: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("Trash/\(copy.filename)").path) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// keeper + ONE identical extra: a two-copy group.
    private func pair(_ label: String) -> Pair {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_duppair_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let size = FileHasher.segmentSize * 2
        let bytes = Data((0..<size).map { UInt8($0 % 181) })
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: bytes)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = dir.path
            r.sizeBytes = Int64(size); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec("keeper.mov", .keep)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        keeper.contentFixity = ContentFixity.captured(path: keeper.fullPath, digest: digest, byteCount: Int64(size))
        let copy = rec("copy.mov", .extraCopy)
        model.records = [keeper, copy]
        return Pair(dir: dir, model: model, keeper: keeper, copy: copy)
    }

    @Test func aFreshBulkRunMovesAPairsExtraWhenItsKeeperIsProven() async throws {
        let p = pair("fresh"); defer { p.cleanup() }
        let job = DeleteDuplicatesJob(model: p.model, volumePath: p.dir.path, hooks: p.hooks, planRoot: p.root)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed, "\(row.status): \(row.note)")
        #expect(p.trashed && FileManager.default.fileExists(atPath: p.keeper.fullPath), "the keeper stays")
    }

    @Test func aPairWhoseKeeperCannotBeProvenIsHeldWithItsReason() async throws {
        let p = pair("unproven"); defer { p.cleanup() }
        // The keeper is gone from its drive: nothing can be proven.
        try FileManager.default.removeItem(atPath: p.keeper.fullPath)
        let job = DeleteDuplicatesJob(model: p.model, volumePath: p.dir.path, hooks: p.hooks, planRoot: p.root)
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.outcome == .held, "\(row.status): \(row.note)")
        #expect(!row.note.isEmpty && !row.note.contains("pre-selected"), Comment(rawValue: row.note))
        #expect(!p.trashed && FileManager.default.fileExists(atPath: p.copy.fullPath), "nothing moved")
    }

    /// A plan saved by an older build (no copy count) is resumed under the
    /// same rule — no tick — and still goes through full proof.
    @Test func aResumedOlderPlanFollowsTheSameRule() async throws {
        let p = pair("resume"); defer { p.cleanup() }
        let plan = DeleteDuplicatesPlan(
            volumePath: p.dir.path, catalogLocation: p.model.catalogStore.fileLocation, crossVolumeMode: false,
            skippedBeforePlan: 0, summaryLine: "",
            entries: [DeleteDuplicatesPlan.Entry(id: p.copy.id, path: p.copy.fullPath, filename: p.copy.filename,
                                                 sizeBytes: p.copy.sizeBytes, keeperID: p.keeper.id,
                                                 keeperPath: p.keeper.fullPath, keeperFilename: p.keeper.filename,
                                                 keeperStamp: FileIdentityStamp.capture(path: p.keeper.fullPath))])
        let job = DeleteDuplicatesJob(model: p.model, resuming: plan, hooks: p.hooks, planRoot: p.root)
        job.start(); await job.task?.value
        #expect(job.plan?.entries.first?.status == .trashed, "\(job.plan?.entries.first?.note ?? "-")")
        #expect(p.trashed)
    }

    /// The Start confirmation forecasts a pair's extra for the Trash — no
    /// "held, not pre-selected" bucket, no tick asked for.
    @Test func theForecastCountsAPairsExtraForTheTrash() {
        let p = pair("forecast"); defer { p.cleanup() }
        let forecast = p.model.deleteDuplicatesForecast(onVolume: p.dir.path)
        #expect(forecast.bucket(for: p.copy.id) == .trash, "\(forecast.buckets)")
        #expect(!forecast.confirmationText(volume: "V").contains("pre-selected"))
    }
}
