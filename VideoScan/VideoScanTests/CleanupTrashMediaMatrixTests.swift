// CleanupTrashMediaMatrixTests.swift
// Triage ▸ Cleanup v1 — MEDIA MATRIX: real ffmpeg, synthetic `test_*`
// fixtures in a temp dir (never family media) — mp4/h264, mov/prores,
// mkv/ffv1+pcm, mxf/mpeg2+pcm, avi/dv. For each format: the plan finds the
// copy by its stored full SHA-256, the job reads both files in full and
// moves the extra copy through the one engine to the test host's scratch
// Trash; the row stays, marked In the Trash, the Trash holds the original
// bytes, and the keeper is untouched. A third "copy" with one byte changed
// (same size, the master's stored hash — a poisoned catalog) is held by the
// fresh read, never moved, its row never stamped.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Cleanup — media matrix", .serialized)
@MainActor
struct CleanupTrashMediaMatrixTests {

    typealias S = CleanupTrashSandbox

    private func run(ext: String, videoCodec: String, extraVideoArgs: [String] = [],
                     audioCodec: String = "pcm_s16le", size: String = "320x240", rate: String = "25") async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let sb = try S("matrix_\(ext)")
        defer { sb.cleanup() }
        let keepDir = try sb.folder("keep"), extraDir = try sb.folder("extra"), otherDir = try sb.folder("other")
        let master = try VerifyVideoTestMedia.generate(into: keepDir, name: "test_cm_master.\(ext)", videoCodec: videoCodec,
                                                       extraVideoArgs: extraVideoArgs, audioCodec: audioCodec,
                                                       size: size, rate: rate)
        let extra = extraDir.appendingPathComponent("test_cm_master.\(ext)")
        try FileManager.default.copyItem(atPath: master, toPath: extra.path)
        // The same file with ONE byte changed mid-stream (same size), stored
        // under the master's digest — a catalog that lies.
        var damaged = try Data(contentsOf: URL(fileURLWithPath: master))
        damaged[damaged.count / 2] ^= 0xFF
        let impostor = otherDir.appendingPathComponent("test_cm_impostor.\(ext)").path
        try damaged.write(to: URL(fileURLWithPath: impostor))
        let digest = try #require(S.sha256(path: master))

        let model = sb.model(keepFirst: ["keep", "extra", "other"])
        let keep = try S.record(URL(fileURLWithPath: master))
        let copy = try S.record(extra)
        let liar = try S.record(URL(fileURLWithPath: impostor), digest: digest)
        model.records = [keep, copy, liar]

        let plan = await model.buildCleanupPlan()
        #expect(Set(plan.copies.map(\.target.id)) == [copy.id, liar.id], "\(ext): \(plan.leftAloneSorted.map(\.reason.words))")
        let job = await runCleanupTrash(model, CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false))
        let byID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.id, $0) })
        #expect(byID[copy.id]?.outcome == .moved, "\(ext): \(job.items.map(\.reason))")
        #expect(byID[liar.id]?.outcome == .held, "\(ext): the fresh read catches the changed byte")
        #expect(!FileManager.default.fileExists(atPath: extra.path))
        #expect(copy.removal?.state == .inTrash && copy.removal?.reason == .duplicate)
        let trash = try #require(copy.removal?.trashPath, "\(ext): the Trash path is on the marker")
        #expect(S.sha256(path: trash) == digest, "\(ext): the Trash holds the original bytes")
        try? FileManager.default.removeItem(atPath: trash)
        #expect(S.sha256(path: master) == digest && keep.removal == nil, "\(ext): the keeper is untouched")
        #expect(FileManager.default.fileExists(atPath: impostor) && liar.removal == nil, "\(ext): the impostor never moves")
    }

    @Test("mp4/h264+aac", .timeLimit(.minutes(2)))
    func mp4() async throws {
        try await run(ext: "mp4", videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
    }

    @Test("mov/prores+pcm", .timeLimit(.minutes(2)))
    func mov() async throws { try await run(ext: "mov", videoCodec: "prores") }

    @Test("mkv/ffv1+pcm", .timeLimit(.minutes(2)))
    func mkv() async throws { try await run(ext: "mkv", videoCodec: "ffv1") }

    @Test("mxf/mpeg2+pcm", .timeLimit(.minutes(2)))
    func mxf() async throws {
        try await run(ext: "mxf", videoCodec: "mpeg2video", extraVideoArgs: ["-g", "15", "-aspect", "4:3"], size: "720x576")
    }

    @Test("avi/dv+pcm", .timeLimit(.minutes(2)))
    func avi() async throws {
        try await run(ext: "avi", videoCodec: "dvvideo", extraVideoArgs: ["-pix_fmt", "yuv411p", "-aspect", "4:3"],
                      size: "720x480", rate: "30000/1001")
    }
}
