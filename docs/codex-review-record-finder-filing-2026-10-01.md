# Codex review — Record Finder filing #230

- Range: `9ed39299..5698cacc`
- Credits spent: unavailable (session billing is not exposed)
- Tokens: 114721
- Finding count: 5
- Verdict: fix — concurrent writes can lose user work, and import failures can misreport files left behind.
- Run: 2026-10-01T21:43:08Z (cycle #18, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (session billing is not exposed) | Finding count: 5
Verdict: fix — concurrent writes can lose user work, and import failures can misreport files left behind.

Reviewed `9ed39299..5698cacc`; the scoped checkout files match `5698cacc`. Findings below are from source analysis. I did not execute new reproductions: this session permits filesystem reads only. The supplied green-suite and mutation results remain the execution evidence.

1. **P1 — Concurrent CyberBrain writers can lose a successfully recorded passage.**  
   [CyberBrainWriter.swift:825](/Users/rickb/dev/VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift:825), [RecordFinderFiling.swift:388](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift:388), [ResearchPersonSheet.swift:171](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift:171).

   `record` performs load → append → save without synchronization. The filing gate coordinates filers, but Research-pane Tell Hallie does not enter it. The dossier lock does not cover CyberBrain writes.

   **Reproduction:** background filing and Research-pane Tell Hallie both load archive A; each appends a different synthetic passage; each saves its own result. The last rename replaces the other passage. Both callers receive successful receipts and persist told IDs, so the missing passage is subsequently treated as already told. The idempotency guard cannot prevent this because both writers inspected the earlier archive.

   This is a pre-existing writer gap exposed by the new background filing path. Add a bounded concurrent-writer test asserting that every successful receipt resolves to its corresponding passage in the final archive. Serialize the complete CyberBrain read-modify-write operation.

2. **P1 — Refreshing a pane’s dossier leaves stale lore drafts that later overwrite newer lore.**  
   [ResearchPersonSheet.swift:150](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift:150), [ResearchPersonSheet.swift:163](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift:163), [ResearchPersonSheet.swift:207](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift:207).

   `mutate` refreshes `dossier` from disk but initializes only *missing* draft entries. `tellHallie` then automatically commits existing drafts.

   **Reproduction:** pane A loads lore `"original"`. Pane B saves `"revised"`. A changes the verdict, causing its dossier to refresh to `"revised"` while its untouched draft remains `"original"`. A presses Tell Hallie. `commitLore` sees the difference and writes `"original"` back to disk. No lore edit in A was necessary.

   Track whether a draft was actually edited; refresh untouched drafts when disk state changes. A two-pane test should assert that `"revised"` survives A’s verdict change and Tell Hallie.

3. **P1 — Re-attachment rollback overwrites a verdict saved after filing began.**  
   [RecordFinderFiling.swift:592](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift:592).

   Rollback restores `verdict` and `fullText` unconditionally from `pre.reattach`, the preparation snapshot. Taking the lock protects the operation from simultaneous execution; it does not establish ownership of the values being overwritten.

   **Reproduction:** file an unread record, remove its document, and re-attach with “read” checked. During the injected CyberBrain callback, save verdict `.wrong`, then throw. Rollback replaces that newer verdict with the original `.unreviewed`.

   Suggested red test, inside the existing filing suite using its synthetic sandbox helpers:

   ```swift
   @Test func reattachRollbackPreservesANewerVerdict() async throws {
       let sb = try sandbox()
       defer { try? fm.removeItem(at: sb.base) }
       let file = try write(try pdf(), "record.pdf", in: sb)

       guard case .filed(_, let id, _) =
           await filer(sb).file(submission(file)) else {
           Issue.record("initial filing failed")
           return
       }
       let document = try #require(sb.store.documents(for: sb.person).first)
       try sb.store.removeDocument(document, for: sb.person)

       let failing: @Sendable (CyberBrainWriter.Testimony) throws
           -> CyberBrainWriter.Receipt = { _ in
               try sb.research.update(key: sb.subject.key) {
                   $0?.setVerdict(.wrong, for: id)
               }
               throw BrainDown()
           }

       _ = await filer(sb, record: .some(failing))
           .file(submission(file, read: true, words: "Synthetic passage."))

       let back = try #require(
           try sb.research.loadDossier(key: sb.subject.key))
       #expect(back.findings.first { $0.id == id }?.verdict == .wrong)
   }
   ```

   Undo needs to restore only changes still attributable to this transaction, preserving later edits.

4. **P2 — Import error types do not establish whether bytes were written or rollback succeeded.**  
   [RecordFinderFiling.swift:314](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift:314), [FamilyAssetStore+Documents.swift:320](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/FamilyAssetStore+Documents.swift:320).

   Every `DocumentError` becomes `.refused`. However, importing can throw `sidecarUnreadable` **after writing the document** and attempting to trash it. The generic catch likewise promises `.rolledBack` without knowing whether the store’s trash move succeeded.

   **Concrete test seam:** start with a readable list and valid PDF. Use `importClock` to corrupt `documents.json` after both filer prechecks pass. Import writes the PDF, discovers the damaged list, moves the PDF to `.trash`, and throws `sidecarUnreadable`. The filer returns `.refused` despite having written document bytes. Pre-create a regular file at `.trash` and the same reproduction leaves an unlisted PDF in Documents while still returning `.refused`.

   Return structured import failure information describing the written file and rollback result. Assert `.rolledBack` for the first case and `.mixedState` for the blocked-trash case, inspecting actual files and rows.

5. **P2 — Document diagnostic logs still expose person-folder names.**  
   [FamilyAssetStore+Documents.swift:173](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/FamilyAssetStore+Documents.swift:173), [FamilyAssetStore+Documents.swift:375](/Users/rickb/dev/VideoScan/VideoScan/FamilyTree/FamilyAssetStore+Documents.swift:375).

   `logSubject` protects successful add/remove messages, but missing-file and unreadable-sidecar messages interpolate the person folder directly. Those folders can contain names. `PersonDocumentLog.write` forwards these strings unchanged to the app log.

   **Reproduction:** create a synthetic folder named `Synthetic_Test_Person`, import a document, remove its underlying file, and list documents. Capture `PersonDocumentLog`’s extra sink and assert the folder name is absent. That assertion fails. A corrupt-sidecar listing exposes the same folder name.

   Use a safe identifier in diagnostics too. Missing-file messages are deduplicated; unreadable-sidecar messages can also flood the log on repeated listing.

Coverage against the requested invariants:

| Invariant | Existing scoped evidence | Missing coverage |
|---|---|---|
| 1. Refusal writes nothing | Bad fields/type/size, unavailable archive, damaged dossier/list tests | Post-precheck failure; snapshot all archive files after refusal |
| 2. No overwrite; duplicates across folders | `anExistingFileNameIsNeverOverwritten`, duplicate/import-route tests | Duplicate located in a second alias/name folder |
| 3. Both writers survive | `anOpenResearchPaneDoesNotEraseARecordFiledMeanwhile`; rerun merge tests | Actual concurrent orders, lore drafts, Tell Hallie, CyberBrain publication |
| 4. Undo only owned changes | Both CyberBrain-failure tests; supplied rollback mutation evidence | Re-attachment with later edits; another writer contributing during rollback; verify retired dossier bytes in research `.trash` |
| 5. Read/words/idempotency/re-attach | Unread/read, placeholder, long transcription, already-told re-attach tests | Concurrent recording; durable repeat with told-state persistence failure; untold re-attach verdict/lore combinations |
| 6. Rollback matches reality | Ordinary rollback/removal tests; `aFailedUndoSaysWhereTheFileIs` | Filesystem failure integration—the latter tests message construction only |
| 7. Private, actionable logging | Filer START/OUTCOME sensor; successful document-store logging sensor | Diagnostic privacy, repeated corrupt-list logging, failed-import outcomes |

The document store has a 500-document timing test, but filing/locking has no comparable populated-dossier or contention sensor in the scoped tests. PNG/JPG/PDF import validation is covered at store level; the end-to-end filer tests use PDFs.

File dispositions:

- **ResearchStore.swift — read, no findings** in the scoped methods.
- **ResearchPerson.swift — read, no findings** in the scoped finding/dossier behavior.
- **ResearchAttestation.swift — read, no findings.**
- **RecordFinderFiling.swift — findings 1, 3, 4.**
- **ResearchPersonSheet.swift — findings 1, 2.**
- **FamilyAssetStore+Documents.swift — findings 4, 5.**
- **CyberBrainWriter.swift — finding 1; sequential idempotency guard read, no additional findings.**
- **RecordFinderFilingTests.swift, RecordFinderAdapterTests.swift, FamilyDocumentStoreTests.swift, ResearchPersonTests.swift — read, no findings beyond the coverage gaps above.**

## Closure (Claude bug-fix agent, 2026-10-01)

Branch `fix/230-codex-filing-findings`, on top of `7f5c5864`. Every finding was fixed red-first: the pinning test was written, run and seen to fail for the reason codex gave, then the fix went in. All runs were Debug and selected by SUITE (never by method), each with its own derivedData under the worktree.

- **1 (P1) Concurrent CyberBrain writers lose a passage**: FIXED `1c2dd64b`. Every durable read-modify-write (`record`, `record(caption:)`, both `setPronunciation`, `correct`) now runs under one in-process `NSLock` per resolved root path (`CyberBrainWriter+RootLock.swift`). The lock lives inside the writer, so the filer, the Research pane's Tell Hallie, Hallie's conversation, the Family Tree notes and the shell all share it without opting in. Process-level coordination is out of scope, as agreed. Pin: `CyberBrainWriterConcurrencyTests.everyReceiptFromConcurrentWritersResolvesToItsPassage` (24 concurrent writers, testimony and captions mixed). Red: 24 receipts but only 3 items on disk, sharing 4 distinct item ids. Green: every receipt resolves to its own passage. Also `spellingsOfOneRootShareALockAndDifferentRootsDoNot`.
- **2 (P1) Stale lore drafts overwrite newer lore**: FIXED `5a57388a`. `ResearchPersonModel` keeps an edited set. Drafts change only through `editLore` (the user typing) or by following the disk. `mutate` refreshes every untouched draft. `commitLore` and `tellHallie` commit only edited drafts, and a failed save keeps the draft marked edited. Pins: `RecordFinderFilingTests.aStaleLoreDraftNeverOverwritesNewerLore` (two panes). Red: A's draft stayed "original", the disk went back to "original", and Hallie was told "original". Green: "revised" survives A's verdict change and Tell Hallie, and Hallie is told "revised". Also `anEditedLoreDraftIsCommittedByTellHallie`, which checks that a real edit is still committed.
- **3 (P1) Re-attach rollback overwrites a newer verdict**: FIXED `05d13d49`. `writeFinding` records a `ReattachWrite` holding exactly the documentPath, verdict and words it set, captured inside the locked change before the save. `restoreDossier` restores each field only while it still holds that value. Pin: codex's `reattachRollbackPreservesANewerVerdict`, verbatim apart from capturing `research`/`key` instead of the sandbox, plus assertions that the words and the document path are still taken back. Red: the verdict came back `.unreviewed`. Green: `.wrong` survives. Known limit: a later writer that sets the *same* value as this filing cannot be told apart from it, so that value is rolled back too.
- **4 (P2) Import failures misreported as `.refused`**: FIXED `4a6dbbfa`. Post-write import failures throw `FamilyAssetStore.DocumentImportFailure {filename, rollback: movedToTrash(URL) | leftInDocuments(reason), underlying}`. The filer checks the disk itself: `.rolledBack` only when the file is out of `Documents/` and at the reported `.trash` path; otherwise `.mixedState`, naming `Documents/<file>`. `DocumentError` is now thrown before the write only. Pins, using the `importClock` seam to damage `documents.json` after both prechecks: `aListDamagedDuringImportIsRolledBackWithTheFileInTrash` and `aListDamagedDuringImportWithTrashBlockedIsMixedStateAndNamesTheFile`. Red: both returned `.refused("…nothing was changed.")`. Green: `.rolledBack` with the PDF in `Documents/.trash/` and named; with a regular file at `.trash`, `.mixedState` naming `Documents/<file>`, and the file really is there. The two existing `FamilyDocumentStoreTests` rollback tests now pin the structured failure.
- **5 (P2) Diagnostics expose the person folder**: FIXED `10e34c3e`. `documents(inPersonFolder:for:)` names the missing-file and unreadable-list lines by `logSubject`: the FamilySearch ID, else the GEDCOM pointer, else an opaque 8-hex folder ref. The folder name goes to os_log only, marked private. The unreadable-list line is written once per (path, size, mtime). Pin: `FamilyDocumentStoreTests.diagnosticLogsNeverNameThePersonFolderAndAreNotRepeated` (serialized suite) with a synthetic `Synthetic_Test_Person` folder. Red: 5 captured lines contained the folder name, the damaged list was logged 4 times, and the missing-file line carried no key. Green: none of these. While checking for the same pattern elsewhere I found one more: `FamilyTreeLiveModel`'s missing-on-disk refusal logged the file's full path. It now logs `Documents/<file>`. Pin: an added assertion in `FamilyDocumentModelTests.aRowWhoseFileIsGoneIsRefusedAndDroppedFromTheList`, red, then green.
- **Coverage gaps**: `876de0df`. `aRefusalChangesNoFileAnywhereInTheArchive` takes path→SHA-256 snapshots across five refusal kinds. `aDuplicateInASecondFolderOfThePersonIsRefused` uses a pointer-keyed twin folder. `aRetiredDossierIsTheExactBytesInResearchTrash` checks the retired dossier byte for byte. All three were green before the fixes, since they pin behavior that was already right. Each was checked by mutation: limiting the duplicate check to the first folder made the twin-folder test fail, and retiring by `removeItem` made the retired-bytes test fail.

Evidence at `876de0df`. App: 228 tests in 31 suites, plus `FamilyTreeLiveModelTests` with 37 tests in 7 suites, all green. That covers RecordFinderFiling, the 3 RecordFinderAdapter suites, FamilyDocumentStore/Model, the 5 Research Person suites, the research-link and research-question suites, every suite whose code reaches a durable CyberBrain writer (Family Tree notes ×5, note correction ×4, model reuse, Hallie telling, photo caption, pronunciation coordinator/drill/lexicon, alias teach), and the remote-viewer read-only sensor. Every intermediate commit (F2 to the gaps commit) was built and run against the filing/document suites: 46, 47, 49, 50 and 53 tests. Core: CyberBrain suites 78/14 green. The full Core package ran 775 tests in 124 suites: 773 passed and 2 timing budgets failed (`FamilyMapTallyTests.fortyThousandPeopleUnderBudget` and `GedcomMergeTests.fullPipelineAtTwoHundredThousandStaysWithinBudget`). Both pass when run alone (0.25 s and 12.3 s); neither file touches CyberBrain. They fail only under the full parallel load.

Not closed (left as named gaps, not findings): a durable repeat when persisting the told state fails; untold re-attach verdict/lore combinations; another writer contributing *during* a rollback; a filing/locking contention sensor at populated-dossier scale; PNG/JPG end-to-end through the filer (store-level only).

## Brief

Scoped data-risk pass for GH #230 Record Finder — the "I found a record" filing path and the per-key research-dossier lock. Range 9ed39299..5698cacc (merged to main as 5698cacc).

Files in scope (do not explore outside these; callers named are for reading only):
- VideoScan/VideoScan/FamilyTree/ResearchStore.swift — ResearchStore.update(key:_:), retireDossierFile(key:), KeyLocks.lock(for:), loadDossier(key:), saveDossier(_:)
- VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift — RecordFilingGate.enter/leave; RecordFinderFiler.file, fileLocked, prepare, checkFields, checkFile, describe, writeDocument, writeFinding, tellHallie, undoAll, restoreDossier, undoDocument, undoFailureMessage, combine, finish
- VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift — ResearchPersonModel.mutate(_:) and callers apply, setVerdict, commitLore, tellHallie
- VideoScan/VideoScan/FamilyTree/FamilyAssetStore+Documents.swift — documentSidecarIsReadable, importPersonDocument, removeDocument, logSubject
- Supporting (read as needed): ResearchPerson.swift (ResearchFinding.fullText/attestationText/isUntranscribedFiledRecord, ResearchDossier.addFiled/markTold/merge), ResearchAttestation.swift (testimony, locator), VideoScanCore/CyberBrainWriter.swift (appending idempotency guard, record)
- Tests: VideoScan/VideoScanTests/RecordFinderFilingTests.swift, RecordFinderAdapterTests.swift, FamilyDocumentStoreTests.swift, ResearchPersonTests.swift

Invariants to attack (rank findings by data-loss risk):
1. Nothing is written before every refusal check passes; ".refused" means zero bytes written anywhere.
2. No existing file is ever overwritten; duplicate SHA-256 is detected across every folder the person has.
3. No dossier writer saves a stale copy: a Research-pane edit (verdict/lore/tell/run) and a concurrent filing both survive, in either order.
4. Undo reverts only this filing's finding from what is on disk now; dossier.json is retired (to research/.trash, never deleted) only if this filing created it and it is otherwise empty.
5. CyberBrain is written only when the user ticked "read" and there is a real transcription or lore; never the placeholder; never twice for the same passage; re-attach after an inspector Remove keeps verdict/told state and does not tell Hallie again.
6. A rollback leaves the document in Documents/.trash with its row gone, and the reported outcome matches reality.
7. Logs (filer and document store) carry no person name, URL or transcription.

Known and accepted (do not report): the per-key lock is in-process only (two app processes are not coordinated); the lock table grows by one entry per researched person per session; a downgrade to an older build cannot decode new ResearchSourceKind cases (documented).

Evidence already run (Debug, by suite, counts confirmed): app 119 tests / 15 suites green incl. RecordFinderFiling (22); Core 111 / 19 green. Mutation: restoreDossier → no-op turns aCyberBrainFailureLeavesNoHalfState and aCyberBrainFailureWithNoPriorDossierLeavesNoDossierFile red. In-house QA pass already closed P1-1, P2-1..4, P3-1..12.

Also check, per Rick's standing directive: new-code test coverage of each invariant (name gaps vs tests run), and logging — actionable START/OUTCOME with context, no flooding.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), and "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.

## Closed

Closed by `793c2e9d` at 2026-10-01T22:24:44Z.
