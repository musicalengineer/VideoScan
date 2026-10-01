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

Wanted: verdict closed / fix/N, findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), and "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
