import Testing
import Foundation
@testable import VideoScanCore

// FindTagIngestEngine — the pure ingest pass (codex QA #279/#281
// seam). Pins the round-3 blocker (save-fail → retry pass must still
// save) and the round-4 cross-process parser races (create-time
// header race, torn-tail offset loss, cursor-persist failure). codex
// owns the wider matrix against this same seam.
struct FindTagIngestEngineTests {

    // MARK: Fixtures

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private func runStartLine(person: String = "Donna",
                              catalogPath: String = "/tmp/catalog.json",
                              recipeID: String = "recipe-v1-native") -> Data {
        let start = FindTagRunStart(
            runId: "R", at: Date(timeIntervalSince1970: 0), person: person,
            recipeID: recipeID, engine: "arcface", catalogPath: catalogPath,
            planned: 9, galleryDigest: "g1", paramsDigest: "p1")
        return try! Self.encoder.encode(FindTagJournalEntry.runStart(start)) + Data([0x0A])
    }

    private func verdictLine(seq: Int, recordID: String, score: Double?) -> Data {
        try! Self.encoder.encode(FindTagJournalEntry.verdict(FindTagVerdict(
            seq: seq, at: Date(timeIntervalSince1970: 1),
            recordID: recordID, path: "/v/\(seq).mov",
            fingerprint: "fp-\(seq)", score: score,
            error: score == nil ? "err" : nil,
            frames: 1, gatedFaces: 1, transport: "avf", seconds: 1))) + Data([0x0A])
    }

    private func journalData(person: String = "Donna",
                             catalogPath: String = "/tmp/catalog.json",
                             recipeID: String = "recipe-v1-native",
                             verdicts: [(seq: Int, recordID: String, score: Double?)])
    -> Data {
        var data = runStartLine(person: person, catalogPath: catalogPath,
                                recipeID: recipeID)
        for verdict in verdicts {
            data += verdictLine(seq: verdict.seq, recordID: verdict.recordID,
                                score: verdict.score)
        }
        return data
    }

    /// One pass against an in-memory journal with scriptable outcomes.
    @discardableResult
    private func runPass(data: Data,
                         fileStates: inout [String: FindTagIngestFileState],
                         cursor: inout FindTagIngestState,
                         applyReturns: Bool = true,
                         saveReturns: Bool = true,
                         persistReturns: Bool = true,
                         saveCalls: inout Int,
                         applyCalls: inout Int,
                         appliedSeqs: inout [Int]) -> FindTagIngestEngine.PassResult {
        var localSaves = 0
        var localApplies = 0
        var localSeqs: [Int] = []
        let result = FindTagIngestEngine.pass(
            journalFiles: [(URL(fileURLWithPath: "/j/run.jsonl"), Int64(data.count))],
            fileStates: &fileStates,
            cursor: &cursor,
            activeCatalogPath: "/tmp/catalog.json",
            isKnownRecipeID: { $0 == "recipe-v1-native" },
            currentGalleryDigest: "g1",
            currentParamsDigest: "p1",
            readData: { _, offset in
                offset >= Int64(data.count) ? Data()
                    : data.subdata(in: Int(offset)..<data.count)
            },
            resolveRecord: { recordID, _ in recordID },   // Record == String
            apply: { _, record, _, _ in
                localApplies += 1
                localSeqs.append(Int(record.split(separator: "-").last.map(String.init) ?? "") ?? -1)
                return applyReturns
            },
            saveCatalog: { localSaves += 1; return saveReturns },
            persistCursor: { _ in persistReturns },
            log: { _ in })
        saveCalls += localSaves
        applyCalls += localApplies
        appliedSeqs += localSeqs
        return result
    }

    // MARK: Round-3 blocker (save-fail → retry must still save)

    @Test func saveFailureThenNoChangeRetryStillForcesSaveBeforeCursor() {
        let data = journalData(verdicts: [(1, "rec-1", 0.7)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        var seqs: [Int] = []

        let pass1 = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                            applyReturns: true, saveReturns: false,
                            saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(!pass1.durable)
        #expect(cursor.appliedSeq["run.jsonl"] == nil, "cursor must hold on failed save")
        #expect(fileStates["run.jsonl"]?.parsedThrough == 0,
                "parse offset must hold on failed save (re-read next pass)")
        #expect(fileStates["run.jsonl"]?.rejected == false,
                "failed save is not a rejection")

        let pass2 = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                            applyReturns: false,   // idempotent no-change replay
                            saveReturns: true,
                            saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(saves == 2, "retry pass MUST attempt the save (round-3 hole: it didn't)")
        #expect(pass2.durable)
        #expect(pass2.applicable == 1, "no-change replay is still APPLICABLE")
        #expect(cursor.appliedSeq["run.jsonl"] == 1, "cursor advances only after durable save")
        #expect(fileStates["run.jsonl"]?.exhausted == true)
    }

    // MARK: Round-4 blocker 1 — create-time header race is not sticky

    @Test func emptyThenPartialHeaderIsNotStickyRejected() {
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        var seqs: [Int] = []

        // Poll 1: writer created the file; nothing written yet.
        runPass(data: Data(), fileStates: &fileStates, cursor: &cursor,
                saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(fileStates["run.jsonl"] == nil,
                "empty file is NOT READY, never rejected")

        // Poll 2: half a runStart, no newline yet.
        let full = journalData(verdicts: [(1, "rec-1", 0.8)])
        runPass(data: full.prefix(20), fileStates: &fileStates, cursor: &cursor,
                saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(fileStates["run.jsonl"] == nil,
                "torn header is NOT READY, never rejected")
        #expect(applies == 0)

        // Poll 3: the complete journal — must classify and apply.
        let result = runPass(data: full, fileStates: &fileStates, cursor: &cursor,
                             saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(applies == 1, "completed file must ingest normally")
        #expect(result.durable)
        #expect(cursor.appliedSeq["run.jsonl"] == 1)
        #expect(fileStates["run.jsonl"]?.rejected == false)
    }

    // MARK: Round-4 blocker 2 — torn verdict tail is re-read, applied once

    @Test func tornVerdictTailIsAppliedExactlyOnceWhenCompleted() {
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        var seqs: [Int] = []

        let header = runStartLine()
        let v1 = verdictLine(seq: 1, recordID: "rec-1", score: 0.7)
        let v2 = verdictLine(seq: 2, recordID: "rec-2", score: 0.9)

        // Poll 1: complete header + v1, then HALF of v2 (no newline).
        let torn = header + v1 + v2.prefix(v2.count / 2)
        let pass1 = runPass(data: torn, fileStates: &fileStates, cursor: &cursor,
                            saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(pass1.durable)
        #expect(applies == 1)
        #expect(seqs == [1])
        #expect(cursor.appliedSeq["run.jsonl"] == 1)
        // The offset must stop at v1's newline — NOT at the torn bytes.
        #expect(fileStates["run.jsonl"]?.parsedThrough == Int64(header.count + v1.count),
                "offset past a torn fragment would silently drop the verdict")

        // Poll 2: writer finished v2 — it must be applied exactly once.
        let complete = header + v1 + v2
        let pass2 = runPass(data: complete, fileStates: &fileStates, cursor: &cursor,
                            saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(pass2.durable)
        #expect(applies == 2, "v2 applied exactly once after completion")
        #expect(seqs == [1, 2])
        #expect(cursor.appliedSeq["run.jsonl"] == 2)
        #expect(fileStates["run.jsonl"]?.parsedThrough == Int64(complete.count))
    }

    // MARK: Round-4 — cursor persist failure holds offsets for retry

    @Test func cursorPersistFailureHoldsOffsetsAndRetries() {
        let data = journalData(verdicts: [(1, "rec-1", 0.7)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        var seqs: [Int] = []

        let pass1 = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                            saveReturns: true, persistReturns: false,
                            saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(!pass1.durable, "lost sidecar = not durable")
        #expect(cursor.appliedSeq["run.jsonl"] == nil,
                "in-memory cursor must not advance past an unpersisted sidecar")
        #expect(fileStates["run.jsonl"]?.parsedThrough == 0,
                "offsets held so the next pass re-reads and retries")

        let pass2 = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                            applyReturns: false, saveReturns: true, persistReturns: true,
                            saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(pass2.durable)
        #expect(cursor.appliedSeq["run.jsonl"] == 1)
    }

    // MARK: Carried round-3 cases

    @Test func errorOnlyJournalCommitsCursorWithoutSave() {
        let data = journalData(verdicts: [(1, "rec-1", nil), (2, "rec-2", nil)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        var seqs: [Int] = []
        let result = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                             saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(saves == 0)
        #expect(applies == 0)
        #expect(result.durable)
        #expect(cursor.appliedSeq["run.jsonl"] == 2)
    }

    @Test func foreignCatalogAndUnknownRecipeAreRejectedSticky() {
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        var seqs: [Int] = []

        let foreign = journalData(catalogPath: "/somewhere/else.json",
                                  verdicts: [(1, "rec-1", 0.9)])
        runPass(data: foreign, fileStates: &fileStates, cursor: &cursor,
                saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(applies == 0, "foreign-catalog journal must never apply")
        #expect(fileStates["run.jsonl"]?.rejected == true)

        // Sticky: a second pass never re-reads it (readData would trap).
        _ = FindTagIngestEngine.pass(
            journalFiles: [(URL(fileURLWithPath: "/j/run.jsonl"), Int64(foreign.count))],
            fileStates: &fileStates, cursor: &cursor,
            activeCatalogPath: "/tmp/catalog.json",
            isKnownRecipeID: { _ in true },
            currentGalleryDigest: nil, currentParamsDigest: nil,
            readData: { _, _ in Issue.record("rejected file must not be re-read"); return nil },
            resolveRecord: { id, _ in id },
            apply: { _, _, _, _ in true },
            saveCatalog: { true },
            persistCursor: { _ in true },
            log: { _ in })

        var fileStates2: [String: FindTagIngestFileState] = [:]
        let unknownRecipe = journalData(recipeID: "recipe-v9-quantum",
                                        verdicts: [(1, "rec-1", 0.9)])
        runPass(data: unknownRecipe, fileStates: &fileStates2, cursor: &cursor,
                saveCalls: &saves, applyCalls: &applies, appliedSeqs: &seqs)
        #expect(applies == 0, "unknown recipeID must fail closed")
        #expect(fileStates2["run.jsonl"]?.rejected == true)
    }

    @Test func orphanedVerdictsAdvanceCursorWithoutSave() {
        let data = journalData(verdicts: [(1, "gone-1", 0.8)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var applies = 0
        var saves = 0
        let result = FindTagIngestEngine.pass(
            journalFiles: [(URL(fileURLWithPath: "/j/run.jsonl"), Int64(data.count))],
            fileStates: &fileStates, cursor: &cursor,
            activeCatalogPath: "/tmp/catalog.json",
            isKnownRecipeID: { _ in true },
            currentGalleryDigest: nil, currentParamsDigest: nil,
            readData: { _, _ in data },
            resolveRecord: { _, _ in nil as String? },   // every record is gone
            apply: { _, _, _, _ in applies += 1; return true },
            saveCatalog: { saves += 1; return true },
            persistCursor: { _ in true },
            log: { _ in })
        #expect(result.orphaned == 1)
        #expect(applies == 0)
        #expect(saves == 0, "orphans are not applicable — no save required")
        #expect(cursor.appliedSeq["run.jsonl"] == 1)
    }
}
