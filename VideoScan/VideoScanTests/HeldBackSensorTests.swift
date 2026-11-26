// HeldBackSensorTests.swift — GH #339 SENSOR: the source keeps the held-back
// feature's promises at the scale of the whole tree.
//   * ONE writer closes held-back rows: `resolveHeldBack(` is called only by
//     HeldBackStore (the confirmed carry) — no job, view or model file;
//   * Find Moved Copies writes nothing: no commit, no carry, no record field;
//   * the sheet carries only from its confirmation dialog — handing over the
//     preview that dialog showed (Codex #385 #2) — and reads no
//     `records` (no O(records) work in a view body).
// Source scans only (comments stripped).

import Foundation
import Testing
@testable import VideoScan

@Suite("Held back at import (#339) — source sensor")
struct HeldBackSensorTests {

    @Test("SENSOR: only HeldBackStore calls resolveHeldBack")
    func oneWriter() throws {
        var callers: [String] = []
        for file in SourceTree.appSources {
            let code = SourceTree.strippingComments(try String(contentsOf: file.url, encoding: .utf8))
            if code.contains("resolveHeldBack(") { callers.append(file.relative) }
        }
        #expect(callers.map { ($0 as NSString).lastPathComponent } == ["HeldBackStore.swift"], "\(callers)")
    }

    @Test("SENSOR: Find Moved Copies writes nothing — no commit, no carry, no record field")
    func jobWritesNothing() throws {
        let code = try SourceTree.appCode(named: "FindMovedCopiesJob.swift")
        for forbidden in ["commit", "writeBlocking", ".carry(", "resolveHeldBack", ".mediaDisposition =", ".userDate =", ".userPlace ="] {
            #expect(!code.contains(forbidden), "FindMovedCopiesJob must not contain \(forbidden)")
        }
    }

    @Test("SENSOR: the sheet carries only from its confirmation dialog and reads no records")
    func sheetConfirmsAndStaysO1() throws {
        let code = try SourceTree.appCode(named: "HeldBackSheet.swift")
        #expect(code.components(separatedBy: "store.carry(").count == 2, "one carry call")
        #expect(code.contains("Button(\"Carry\") { Task { finish(await store.carry(p)) } }"), "only the confirmation's Carry, with the preview it showed")
        #expect(code.contains("await store.previewCarryNow("), "the confirmation's preview reads the stored conflicts first (Codex #389 P1)")
        #expect(!code.contains("store.previewCarry("), "never a preview judged without the stored conflicts")
        #expect(!code.contains("records"))
        #expect(!code.contains("model."))
    }
}
