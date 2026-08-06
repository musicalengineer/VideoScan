import Testing
import Foundation
@testable import VideoScanCore

// FindTagIngestEngine — the pure ingest pass (codex QA #279 seam).
// These pin the round-3 BLOCKER (save-fail → retry pass must still
// save before committing the cursor); codex owns the wider matrix
// (viewer gate, foreign catalog, scale, UUID fallback) against this
// same seam.
struct FindTagIngestEngineTests {

    // MARK: Fixtures

    private func journalData(person: String = "Donna",
                             catalogPath: String = "/tmp/catalog.json",
                             recipeID: String = "recipe-v1-native",
                             verdicts: [(seq: Int, recordID: String, score: Double?)])
    -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var lines: [Data] = []
        let start = FindTagRunStart(
            runId: "R", at: Date(timeIntervalSince1970: 0), person: person,
            recipeID: recipeID, engine: "arcface", catalogPath: catalogPath,
            planned: verdicts.count, galleryDigest: "g1", paramsDigest: "p1")
        lines.append(try! encoder.encode(FindTagJournalEntry.runStart(start)))
        for verdict in verdicts {
            lines.append(try! encoder.encode(FindTagJournalEntry.verdict(FindTagVerdict(
                seq: verdict.seq, at: Date(timeIntervalSince1970: 1),
                recordID: verdict.recordID, path: "/v/\(verdict.seq).mov",
                fingerprint: "fp-\(verdict.seq)", score: verdict.score,
                error: verdict.score == nil ? "err" : nil,
                frames: 1, gatedFaces: 1, transport: "avf", seconds: 1))))
        }
        return Data(lines.map { $0 + Data([0x0A]) }.joined())
    }

    /// One pass against an in-memory journal with scriptable
    /// save/apply outcomes.
    private func runPass(data: Data,
                         fileStates: inout [String: FindTagIngestFileState],
                         cursor: inout FindTagIngestState,
                         applyReturns: Bool,
                         saveReturns: Bool,
                         saveCalls: inout Int,
                         applyCalls: inout Int) -> FindTagIngestEngine.PassResult {
        var localSaves = 0
        var localApplies = 0
        let result = FindTagIngestEngine.pass(
            journalFiles: [(URL(fileURLWithPath: "/j/run.jsonl"), Int64(data.count))],
            fileStates: &fileStates,
            cursor: &cursor,
            activeCatalogPath: "/tmp/catalog.json",
            isKnownRecipeID: { $0 == "recipe-v1-native" },
            currentGalleryDigest: "g1",
            currentParamsDigest: "p1",
            readData: { _, offset in
                offset >= Int64(data.count) ? Data() : data.subdata(in: Int(offset)..<data.count)
            },
            resolveRecord: { recordID, _ in recordID },   // Record == String
            apply: { _, _, _, _ in localApplies += 1; return applyReturns },
            saveCatalog: { localSaves += 1; return saveReturns },
            log: { _ in })
        saveCalls += localSaves
        applyCalls += localApplies
        return result
    }

    // MARK: THE round-3 blocker

    @Test func saveFailureThenNoChangeRetryStillForcesSaveBeforeCursor() {
        // Poll 1: apply mutates memory (returns true), save FAILS.
        // Poll 2: apply returns false (memory already has the tier —
        // the exact codex #279 replay), save SUCCEEDS.
        // The cursor must not move until poll 2's save; poll 2 MUST
        // call save even though nothing newly applied.
        let data = journalData(verdicts: [(1, "rec-1", 0.7)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0

        let pass1 = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                            applyReturns: true, saveReturns: false,
                            saveCalls: &saves, applyCalls: &applies)
        #expect(!pass1.durable)
        #expect(cursor.appliedSeq["run.jsonl"] == nil, "cursor must hold on failed save")
        #expect(fileStates["run.jsonl"]?.parsedThrough == 0,
                "parse offset must hold on failed save (re-read next pass)")

        let pass2 = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                            applyReturns: false,   // idempotent no-change replay
                            saveReturns: true,
                            saveCalls: &saves, applyCalls: &applies)
        #expect(saves == 2, "retry pass MUST attempt the save (round-3 hole: it didn't)")
        #expect(pass2.durable)
        #expect(pass2.applicable == 1, "no-change replay is still APPLICABLE")
        #expect(cursor.appliedSeq["run.jsonl"] == 1, "cursor advances only after durable save")
        #expect(fileStates["run.jsonl"]?.exhausted == true)
    }

    @Test func errorOnlyJournalCommitsCursorWithoutSave() {
        // Errors carry no score → nothing applicable → no save needed;
        // the cursor may advance directly.
        let data = journalData(verdicts: [(1, "rec-1", nil), (2, "rec-2", nil)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0
        let result = runPass(data: data, fileStates: &fileStates, cursor: &cursor,
                             applyReturns: true, saveReturns: true,
                             saveCalls: &saves, applyCalls: &applies)
        #expect(saves == 0)
        #expect(applies == 0)
        #expect(result.durable)
        #expect(cursor.appliedSeq["run.jsonl"] == 2)
    }

    @Test func foreignCatalogAndUnknownRecipeAreRejectedSticky() {
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0, applies = 0

        let foreign = journalData(catalogPath: "/somewhere/else.json",
                                  verdicts: [(1, "rec-1", 0.9)])
        _ = runPass(data: foreign, fileStates: &fileStates, cursor: &cursor,
                    applyReturns: true, saveReturns: true,
                    saveCalls: &saves, applyCalls: &applies)
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
            log: { _ in })

        var fileStates2: [String: FindTagIngestFileState] = [:]
        let unknownRecipe = journalData(recipeID: "recipe-v9-quantum",
                                        verdicts: [(1, "rec-1", 0.9)])
        _ = runPass(data: unknownRecipe, fileStates: &fileStates2, cursor: &cursor,
                    applyReturns: true, saveReturns: true,
                    saveCalls: &saves, applyCalls: &applies)
        #expect(applies == 0, "unknown recipeID must fail closed")
        #expect(fileStates2["run.jsonl"]?.rejected == true)
    }

    @Test func orphanedVerdictsAdvanceCursorWithoutSave() {
        let data = journalData(verdicts: [(1, "gone-1", 0.8)])
        var fileStates: [String: FindTagIngestFileState] = [:]
        var cursor = FindTagIngestState()
        var saves = 0
        var applies = 0
        var localSaves = 0
        let result = FindTagIngestEngine.pass(
            journalFiles: [(URL(fileURLWithPath: "/j/run.jsonl"), Int64(data.count))],
            fileStates: &fileStates, cursor: &cursor,
            activeCatalogPath: "/tmp/catalog.json",
            isKnownRecipeID: { _ in true },
            currentGalleryDigest: nil, currentParamsDigest: nil,
            readData: { _, _ in data },
            resolveRecord: { _, _ in nil as String? },   // every record is gone
            apply: { _, _, _, _ in applies += 1; return true },
            saveCatalog: { localSaves += 1; return true },
            log: { _ in })
        saves += localSaves
        #expect(result.orphaned == 1)
        #expect(applies == 0)
        #expect(saves == 0, "orphans are not applicable — no save required")
        #expect(cursor.appliedSeq["run.jsonl"] == 1)
    }
}
