// JunkBytesMovedTests.swift
// Design R7 (codex design review F7, 2026-10-09): the bytes a Delete Junk
// run reports are the SUM OF THE MOVED FILES' SIZES — "moved to the
// Trash", not "freed" (space comes back when Rick empties the Trash).
//
// Before: JunkDeleteAction scaled the counted bytes by the success RATIO,
// so one tiny success and one huge hold reported half the total.

import Foundation
import Testing
@testable import VideoScan

@Suite("Delete Junk — bytes moved are the moved files' sizes", .serialized)
@MainActor
struct JunkBytesMovedTests {

    /// Through the real button path (makeOnAct → trashFrozenJunk → the
    /// real Trash for the small file; the big one is held at its turn).
    @Test("1 KB moved + 1 MB held reports 1 KB, not half of 1.001 MB")
    func bytesAreTheMovedFilesSizes() async throws {
        let sb = try JunkTrashSandbox("bytes"); defer { sb.cleanup() }
        let model = sb.model()
        let smallName = "test_junkbytes_\(UUID().uuidString).mov"
        let small = sb.junk(try sb.write(smallName, bytes: 1_000))
        let big = sb.junk(try sb.write("test_big.mov", bytes: 1_000_000))
        model.records = [small, big]
        let snapshot = await model.freezeJunkSnapshot([small, big], isOffline: { _ in false })
        #expect(snapshot.moveBytes == 1_001_000)
        big.mediaDisposition = .unreviewed                 // held at its turn

        let done = BytesProbe()
        let onAct = JunkDeleteAction.makeOnAct(model: model, snapshot: snapshot) { _, bytes in
            done.bytes = bytes
        }
        onAct()
        let deadline = ContinuousClock.now + .seconds(20)
        while done.bytes == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let trash = try #require(FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first)
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(smallName))   // our own fixture

        #expect(done.bytes == 1_000, "bytes moved = the moved file's size: \(String(describing: done.bytes))")
        #expect(FileManager.default.fileExists(atPath: big.fullPath))
    }

    @Test("the routine measures each moved file at its turn; held / missing files add nothing; the report says 'moved to the Trash'")
    func routineSumsMovedSizes() async throws {
        let sb = try JunkTrashSandbox("bytesum"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_a.mov", bytes: 1_000))
        let b = sb.junk(try sb.write("test_b.mov", bytes: 3_000))
        b.sizeBytes = 99                                   // a stale catalog size is not what moved
        let held = sb.junk(try sb.write("test_held.mov", bytes: 5_000))
        let gone = sb.junk(sb.files.appendingPathComponent("test_gone.mov"))
        gone.sizeBytes = 7_000
        model.records = [a, b, held, gone]

        let result = await model.deleteConfirmedJunk([a, b, held, gone], mode: .toTrash, guard: .init(
            authorize: { $0 === held ? "not this one" : nil }, beforeRemoval: { _ in nil },
            remove: sb.trash.operation))
        #expect(result.succeeded == 2 && result.bytesMoved == 4_000, "\(result.bytesMoved)")
        let report = JunkDeletionReport(result)
        #expect(report.bytesMoved == 4_000)
        #expect(report.summary.first == "Moved 2 files (\(Formatting.humanSize(4_000))) to the Trash")
    }

    @Test("sensor: no ratio scaling and no 'freed' on the junk paths")
    func noScalingNoFreed() throws {
        let action = try SourceTree.appCode(named: "JunkDeleteAction.swift")
        #expect(action.contains("onComplete(result, result.bytesMoved)"))
        #expect(!action.contains("Double(result.succeeded)"), "the success-ratio estimate is back")
        for file in JunkTrashOnlyTests.junkLaneFiles {
            let code = try SourceTree.appCode(named: file)
            #expect(!code.lowercased().contains("freed"), "\(file) says freed")
        }
    }
}

@MainActor
final class BytesProbe {
    var bytes: Int64?
}
