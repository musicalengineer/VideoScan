# Codex review — Documents sidecar + #18 fixes

- Range: `7f5c5864..c9caac20`
- Credits spent: unavailable
- Tokens: 71465
- Finding count: 4
- Verdict: fix — rollback can erase concurrent edits, failed lore saves can lose their retry, and unknown-kind rewrites break legacy decoding.
- Run: 2026-10-02T01:13:50Z (cycle #19, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: fix — rollback can erase concurrent edits, failed lore saves can lose their retry, and unknown-kind rewrites break legacy decoding.

Reviewed `7f5c5864..c9caac20` within the named files. No files changed or tests rerun: the sandbox is read-only. Credit consumption is not exposed to this session. Red tests below are proposed, not executed.

1. **P1 — New-finding rollback deletes another writer’s edits.**  
   [RecordFinderFiling.swift:648](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift:648)

   The new-finding branch unconditionally removes the finding. If another writer saves lore or changes its verdict after insertion, a subsequent CyberBrain failure deletes that newer work and can report `.rolledBack`.

   Deterministic red test, inserted into `RecordFinderFilingTests` using its existing helpers:

   ```swift
   @Test func newFindingRollbackPreservesAnotherWritersLore() async throws {
       let sb = try sandbox()
       defer { try? fm.removeItem(at: sb.base) }
       let research = sb.research, key = sb.subject.key
       let failing: @Sendable (CyberBrainWriter.Testimony) throws
           -> CyberBrainWriter.Receipt = { _ in
           let current = try #require(try research.loadDossier(key: key))
           let finding = try #require(
               current.findings.first { $0.source == .recordFinder })
           try research.update(key: key) {
               $0?.setLore("Synthetic later edit", for: finding.id)
           }
           throw BrainDown()
       }
       let file = try write(try pdf(), "synthetic.pdf", in: sb)
       _ = await filer(sb, record: .some(failing))
           .file(submission(file, read: true, words: "Synthetic filing text"))
       let back = try research.loadDossier(key: key)
       #expect(back?.findings.first?.lore == "Synthetic later edit")
       // Current result: nil.
   }
   ```

   Rollback needs to detect subsequent changes before deleting the inserted finding. Retaining another writer’s changes may require a `.mixedState` outcome because the document has been retired.

2. **P1 — Re-attachment rollback restores an outdated baseline.**  
   [RecordFinderFiling.swift:641](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift:641), also line 644.

   The ownership comparison protects changes made **after** `writeFinding`, but restoration uses `pre.reattach`, captured during `prepare`. Changes saved between preparation and the locked mutation are lost.

   Concrete reproduction:

   - File an unread synthetic PDF, then remove its document.
   - Set `importClock` to save `.wrong` and `"Synthetic intervening text"` into that finding on its first invocation. This runs after `prepare` and before `writeFinding`.
   - Refile as confirmed with `"Synthetic replacement"`.
   - Have the injected CyberBrain writer throw `BrainDown()`.

   Expected red assertions:

   ```swift
   #expect(back.verdict == .wrong)
   #expect(back.fullText == "Synthetic intervening text")
   ```

   Current results are `.unreviewed` and `nil`, restored from the preparation snapshot. Capture both previous and written values inside the same `researchStore.update` closure.

3. **P2 — A failed lore save clears its edited flag on retry without saving.**  
   [ResearchPersonSheet.swift:177](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift:177)

   `mutate` applies failed changes to the local dossier at line 236. The next `commitLore` compares against that optimistic local value, skips persistence, and clears `editedLore` at line 182.

   Deterministic red test using existing helpers:

   ```swift
   @MainActor
   @Test func aFailedLoreSaveIsActuallyRetried() async throws {
       let sb = try sandbox()
       defer { try? fm.removeItem(at: sb.base) }
       let file = try write(try pdf(), "synthetic.pdf", in: sb)
       guard case .filed(_, let id, _) =
           await filer(sb).file(submission(file)) else {
           Issue.record("initial filing failed"); return
       }
       let model = pane(sb)
       model.load()
       let url = try sb.research.dossierURL(key: sb.subject.key)
       let original = try Data(contentsOf: url)
       try Data("{ damaged".utf8).write(to: url)
       model.editLore("Synthetic unsaved draft", for: id)
       model.commitLore(for: id)
       #expect(model.errorMessage != nil)
       try original.write(to: url)
       model.commitLore(for: id)
       let back = try sb.research.loadDossier(key: sb.subject.key)
       #expect(back?.findings.first { $0.id == id }?.lore
               == "Synthetic unsaved draft")
       // Current result: empty lore.
   }
   ```

   An edited draft must be persisted or compared against the locked disk value before clearing its edited flag.

4. **P2 — Unknown-kind preservation emits lists the frozen legacy reader rejects.**  
   [FamilyAssetStore+Documents.swift:235](/Users/rickb/dev/VideoScan/VideoScan/VideoScan/FamilyTree/FamilyAssetStore+Documents.swift:235)

   `unrecognizedKindCode` is written directly into `kind`. Reading a future `"kind":"WILL"` row and importing another document successfully rewrites a list that the legacy enum rejects wholesale.

   The existing test at [FamilyDocumentStoreTests.swift:572](/Users/rickb/dev/VideoScan/VideoScan/VideoScanTests/FamilyDocumentStoreTests.swift:572) explicitly expects this incompatible encoding. Add the following after its import to expose the conflict:

   ```swift
   let rewritten = try Data(contentsOf:
       documentsDir(folder).appendingPathComponent(
           FamilyAssetStore.documentsSidecarName))
   _ = try Self.legacySidecarDecoder.decode(
       [LegacyPersonDocument].self, from: rewritten)
   // Throws DecodingError.dataCorrupted for kind "WILL".
   ```

   Preserve unknown codes in optional metadata while keeping emitted `kind` within `BC/DC/MC/Other`.

The #18 fixes are therefore **partially confirmed**: scoped durable writers serialize load→change→save; untouched lore follows newer disk values; re-attachment rollback preserves a verdict changed after its mutation; structured import failures distinguish trash rollback from an orphan left in Documents. The failure cases above remain.

Coverage against the requested invariants:

| Invariant | Existing coverage and remaining gaps |
|---|---|
| 1 — Writer locking | 24 concurrent testimony/caption writers covered. Missing concurrent pronunciation writers, error-unlock, actual concurrent alias/symlink writes, independent-root progress, and bounded deadlock detection. Durable writers outside the allowed files remain uncertified. |
| 2 — Lore drafts | Successful untouched/edited paths covered. Missing failed-save→retry sensor; finding 3 exposes it. |
| 3 — Owned-field rollback | Post-mutation reattach verdict covered. Missing newly inserted finding edited by another writer and intervening pre-mutation values; findings 1–2 expose both. |
| 4 — Disk-truth failures | Damaged-list rollback and blocked-trash mixed state covered. Missing read-back mismatch, sidecar publication failure, and removal publication failure. |
| 5 — Compatibility | Known kinds, old lists, old re-save recovery, and unknown categories covered. Missing legacy decoding after unknown-kind rewrite; finding 4 exposes it. |
| 6 — Privacy | Scoped DNA document exclusion and living-outsider gather filtering are correct. No automatic DNA-to-research filing route found in scope. Publish paths outside these files cannot be certified. |
| 7 — Logging | Filer START/OUTCOME and diagnostic privacy/dedup sensors exist. Store import/remove and Research Tell Hallie lack START records. Successful import rollback has no store outcome. Raw rollback-error logging at Documents line 741 lacks a privacy assertion; no identifying error string was confirmed within scope. |

Your supplied Debug results remain the execution evidence: #18 app **228/31**, FamilyTreeLiveModel **37/7**, Core **78/14**, and sidecar app **143/14**. Those passing suites do not cover the four reproductions above.

Per-file disposition:

| File | Result |
|---|---|
| `CyberBrainWriter.swift` | Read, no findings. |
| `CyberBrainWriter+RootLock.swift` | Read, no findings. |
| `RecordFinderFiling.swift` | Findings 1–2. |
| `ResearchPersonSheet.swift` | Finding 3. |
| `FamilyAssetStore+Documents.swift` | Finding 4. |
| `FamilyTreeMemories.swift` | Read, no findings within scoped paths. |
| `RecordFinderFilingTests.swift` | Read, no findings; coverage gaps above. |
| `FamilyDocumentStoreTests.swift` | Incompatible expectation associated with finding 4. Frozen Legacy reader: read, no findings. |
| `FamilyTreeMemoriesTests.swift` | Read, no findings. |
| `CyberBrainWriterConcurrencyTests.swift` | Read, no findings. |

## Brief

Scoped data-risk pass (bundled, overnight 2026-10-01→02): (A) confirm the fixes for codex cycle #18 (Record Finder filing) and (B) attack the new person-documents sidecar encoding. Range 7f5c5864..c9caac20 — review ONLY the files below; the range also contains a docs/ reorganization and unrelated merges you must ignore.

Files in scope (do not explore outside these; callers named are for reading only):
- VideoScan/VideoScanCore/Sources/VideoScanCore/CyberBrainWriter.swift, CyberBrainWriter+RootLock.swift — record(_:rootURL:), appending(_:to:), the root lock
- VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift — fileLocked, prepare, writeFinding, tellHallie, undoAll, restoreDossier (owned-field rollback), documentKind, import-failure mapping
- VideoScan/VideoScan/FamilyTree/ResearchPersonSheet.swift — ResearchPersonModel.mutate, editLore, commitLore, tellHallie (edited-draft tracking)
- VideoScan/VideoScan/FamilyTree/FamilyAssetStore+Documents.swift — PersonDocument / kind + category encoding and decoding, filename-prefix recovery, importPersonDocument (structured failure), removeDocument, documentSidecarIsReadable, diagnostics/logSubject
- VideoScan/VideoScan/FamilyTree/FamilyTreeMemories.swift — providers' privacy filter (DNA exclusion, living-person rule) — read-only paths
- Tests: VideoScan/VideoScanTests/RecordFinderFilingTests.swift, FamilyDocumentStoreTests.swift (incl. the frozen Legacy reader), FamilyTreeMemoriesTests.swift, VideoScan/VideoScanCore/Tests/VideoScanCoreTests/CyberBrainWriterConcurrencyTests.swift

Invariants to attack (rank by data-loss risk):
1. Every durable CyberBrain write (all callers, not just the filer) holds the per-root lock for its whole load→change→save; no successful receipt can be lost; no deadlock (lock re-entry, lock held across await, lock ordering with the dossier key lock).
2. A stale Research-pane draft never overwrites newer lore; an edited draft is committed exactly once; a failed save keeps it marked edited.
3. Rollback restores a field only if it still holds the value this filing wrote; it never clobbers a later writer's change.
4. An import failure reports what is actually on disk (.refused ⇒ zero bytes written; .rolledBack ⇒ file in .trash and row gone; .mixedState names the real location).
5. Sidecar forward/backward compatibility: a build from 41cba21b (frozen Legacy reader) decodes every list this build writes without reporting damage; this build reads old lists; after an OLD build re-saves a list (dropping `category`), DNA/MIL/CEN kinds are recovered and DNA stays private; unknown future kind/category values round-trip unchanged; no path writes a kind code the legacy enum cannot decode.
6. DNA documents never reach Hallie, memories, or any publish path; living people outside the inner circle never appear in memories.
7. Logs carry no person name, folder name, URL or transcription.

Known and accepted (do not report): locks are in-process only (two app processes are not coordinated); an older build shows MIL/CEN/DNA as "Other document" without a lock badge; the lock table grows by one entry per researched person per session.

Evidence already run (Debug, by suite, counts confirmed): #18 fixes — app 228 tests / 31 suites + FamilyTreeLiveModel 37 / 7, Core CyberBrain 78 / 14, CyberBrainWriterConcurrencyTests 24 concurrent writers; sidecar — app 143 / 14 incl. frozen Legacy reader; mutation checks noted in docs/reviews/codex/codex-review-record-finder-filing-2026-10-01.md (Closure section).

Also check, per Rick's standing directive: new-code test coverage of each invariant (name gaps vs tests run) and logging (actionable START/OUTCOME, no flooding).

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), and "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
