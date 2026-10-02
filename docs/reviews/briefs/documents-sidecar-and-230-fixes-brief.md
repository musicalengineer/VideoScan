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
