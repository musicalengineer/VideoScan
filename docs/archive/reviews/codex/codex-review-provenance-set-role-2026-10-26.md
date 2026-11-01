# Codex review — Provenance Set Role — provenance_roles v13 + its one writer

- Range: `main..feat/provenance-set-role`
- Credits spent: unavailable
- Tokens: 86097
- Finding count: 2
- Verdict: fix — the cache can silently discard a role change, and the Inspector can render the previous content’s role.
- Run: 2026-10-27T00:20:36Z (cycle #156, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2  
Verdict: fix — the cache can silently discard a role change, and the Inspector can render the previous content’s role.

Reviewed `06717e279..80f4ba155`. **36 existing tests passed:** 13 Core tests and 23 app tests. No source edits. Regression cases below are proposed, not witnessed RED; the sandbox denied the standalone Swift harness.

1. **A stale cache can discard Rick’s role choice.**  
   [ProvenanceRoleStore.swift:276](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a73c9f988afba2493/VideoScan/VideoScan/Provenance/ProvenanceRoleStore.swift:276)

   `set` excludes cache-matching digests before entering the transaction. Those digests never receive the advertised SQL recheck.

   **Reproduction:** persist Master, attach the store, then choose Unknown before `load()` completes. Attachment clears the map; `isAlready(.unknown, false, nil)` returns true. The outcome reports unchanged, while SQLite retains Master.

   A second route exists at line 210: a suspended `load()` can overwrite a newer committed cache entry with its older snapshot. Choosing that cached role then skips a real change. No second writer is needed.

   **Proposed RED assertions**, using the existing launched-scene fixture and healthy digest `d`:

   ```swift
   let store = scene.model.provenanceRoles
   _ = store.set(.master, digests: [d])
   store.attach(try #require(store.backing))
   #expect(store.set(.unknown, digests: [d])
           == .set(changed: 1, unchanged: 0))
   #expect(try await history(scene.model, d).map(\.role)
           == [.master, .unknown])
   ```

   Check every selected digest inside the transaction, refresh all selected readings, and prevent obsolete loads from replacing newer state.

2. **The Inspector’s saved reading is not tied to its digest or revision.**  
   [InspectorProvenanceRoleLine.swift:40](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a73c9f988afba2493/VideoScan/VideoScan/Provenance/InspectorProvenanceRoleLine.swift:40)

   **Reproduction:** complete the read for content A, then change to B while retaining the view’s identity. `body` passes A’s saved `reading` alongside B’s digest. `lines` checks only whether the digest is nonnil, so it renders A’s role. Clearing `reading` inside the subsequent `.task` does not guard that preceding evaluation. Revision changes have the same stale-state window.

   **Proposed RED assertion**, with `masterA.digest == hex(1)`:

   ```swift
   #expect(InspectorProvenanceRoleLine.lines(
       digest: hex(2), reading: .row(masterA)
   ) == ["Role: …"])
   ```

   Store the completed `ReadKey` alongside the result; render “Role: …” whenever it differs from the current digest/revision.

The remaining scoped files were reviewed as follows; parenthetical restrictions match your brief:

| File | Result |
|---|---|
| `Store/CatalogProvenanceRolesSchema.swift` | read, no findings |
| `Store/CatalogProvenanceRoleRows.swift` | read, no findings |
| `Store/GRDBCatalogRepository+ProvenanceRoles.swift` | read, no findings |
| `Store/GRDBCatalogRepository.swift` (migration registration) | read, no findings |
| `Store/CatalogRepository.swift` (protocol composition) | read, no findings |
| `Provenance/ProvenanceMenu.swift` | read, no findings |
| `Catalog/CatalogCommitter.swift` (`SideTable.provenanceRoles`) | read, no findings |
| `Catalog/CatalogAuthorityFlip.swift` (attach lines) | read, no findings |
| `ModelsUI/ArchiveModels+Presentation.swift` (`displayName`) | read, no findings |
| `docs/design/catalog_sqlite_schema_v1.sql` §17 | read, no findings |
| `VideoScanCoreTests/Store/CatalogProvenanceRolesTests.swift` | read, no findings |
| `VideoScanTests/ProvenanceSetRoleTests.swift` | read, no findings |
| `VideoScanTests/ArchiveStageArchivedLabelTests.swift` | read, no findings |

I stayed within the named implementation/test scope. Digest resolution, file-row binding, and excluded commit-door internals were not independently re-reviewed.

## Brief

# Codex review brief — Provenance ▸ Set Role: `provenance_roles` (schema v1.12, version 13) and its one writer (data-risk, rule 10: a writer of Rick's curated data)

**Workflow in one sentence (Rick's words):** "say what this file is — Master, Camera Original, … — and have every copy of it say the same, for good."

**Rulings (docs/DECISIONS.md, 2026-10-26, Rick):** no file is a designated master yet (every role Unknown until Rick sets it); the Archive tab stops labelling files "Masters" (stage stored as `Master` is shown as "Archived", stored value unchanged); provenance roles Master · Camera Original · Alternate Capture · Remastered Copy · Edit Copy · Excerpt · View Copy · Test Copy · Unknown, a role belongs to the content (SHA-256), only Rick sets one, an only-surviving copy may be Master with "source not in the catalog"; schema `provenance_roles` approved — one additive, append-only table (digest → role, decided_at, source_missing, note), current = newest row per digest, no row = Unknown, written only through the commit door. Policy: `docs/guides/provenance_roles.md`.

**Range:** `main..feat/provenance-set-role`. **Worktree:** `/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a73c9f988afba2493` (read-only for you).

**Shape:**
- Core: migration `v8_provenance_roles` (`Store/CatalogProvenanceRolesSchema.swift`) registered after `v7_decision_tables`; STRICT table `provenance_roles(role_id INTEGER PRIMARY KEY, digest → content(digest) ON DELETE RESTRICT, role CHECK IN 9 keys, decided_at, source_missing CHECK 0/1, note)`, index `(digest, role_id)`, no-update/no-delete triggers; `schema_version`/`user_version` 12 → 13. Doors in `Store/GRDBCatalogRepository+ProvenanceRoles.swift`: `appendProvenanceRole` (plain INSERT; returns `.contentMissing` without writing when the digest is not a `content` row), `currentProvenanceRoles(digests:)` (`ORDER BY role_id DESC LIMIT 1` per digest), `currentProvenanceRoles(visit)` (GROUP BY max(role_id) join), `provenanceRoleHistory`. Values in `Store/CatalogProvenanceRoleRows.swift` (`ProvenanceRole` keys; an unknown stored key reads back verbatim, `role` = Unknown).
- App: `Provenance/ProvenanceRoleStore.swift` — the one engine. `set(role, digests:, sourceMissing:)` refuses before writing (no backing / `writeRefusal`), skips contents already in the role (by the map), then ONE `committer.commitSideTables(…, via: .provenanceRoles)` transaction: re-reads current rows inside the tx, appends only changed ones, throws (whole rollback) on `.contentMissing`, reads back inside the tx and updates the map from that read-back. Attached in `CatalogAuthorityFlip.adoptSQLiteAuthority`. `Provenance/ProvenanceMenu.swift` — Provenance ▸ Find ▸ Master (sound) (moved, unchanged) · Set Role ▸ nine `Toggle`s, checkmark = common role; disabled with a tooltip when any selected file has no whole-file digest (`CatalogCommit.digest(of:)`) or the session may not write; Master asks once (NSAlert, checkbox "Source not in the catalog (this is the only surviving version)"). `Provenance/InspectorProvenanceRoleLine.swift` — reads catalog.sqlite (`readCurrent`) on every (digest, revision) change; "Role: …" while reading.
- Label: `ArchiveStage.displayName` (`.masterAssigned` → "Archived") used by the Archive detail sheet, the Archive Angel reason sentence, Hallie's record phrase and metadata line, and catalog search (display label added; the stored word still matches).

**In scope:** `VideoScan/VideoScanCore/Sources/VideoScanCore/Store/CatalogProvenanceRolesSchema.swift`, `Store/CatalogProvenanceRoleRows.swift`, `Store/GRDBCatalogRepository+ProvenanceRoles.swift`, `Store/GRDBCatalogRepository.swift` (the migration registration only), `Store/CatalogRepository.swift` (protocol composition only); `VideoScan/VideoScan/Provenance/ProvenanceRoleStore.swift`, `Provenance/ProvenanceMenu.swift`, `Provenance/InspectorProvenanceRoleLine.swift`, `Catalog/CatalogCommitter.swift` (the `SideTable.provenanceRoles` case only), `Catalog/CatalogAuthorityFlip.swift` (the attach lines only), `ModelsUI/ArchiveModels+Presentation.swift` (`displayName`); `docs/design/catalog_sqlite_schema_v1.sql` §17. Tests: `VideoScanCoreTests/Store/CatalogProvenanceRolesTests.swift`, `VideoScanTests/ProvenanceSetRoleTests.swift`, `VideoScanTests/ArchiveStageArchivedLabelTests.swift`.

**Invariants to attack:**
1. **Append-only, newest wins.** Find any path that UPDATEs/DELETEs/REPLACEs a role row, or where "current" is not the highest role_id (digest case — digests are lowercased on write and read; is any caller passing an uppercase or `sha256:`-prefixed digest that silently misses?).
2. **Role is per content, never per path.** Can two byte copies ever show different roles? Can a record whose `CatalogCommit.digest(of:)` disagrees with the digest its `files` row carries (content vs archive fixity, a size change) get a role written to the wrong content — or be shown another content's role?
3. **One writer, refuse before mutating.** Every refusal (no committer, viewer, read-only launch, write hold, blocked/reopening store, file-stop, content missing) writes nothing and is said in words; nothing is reported as set unless the transaction committed. Is there a race between the map-based "already" filter and the in-tx re-check that can drop a real change or write a duplicate? Does a refused/thrown side-table commit ever set `blockedReason` or disturb the record committer's baseline / generation CAS (a role set inside the 2 s debounce window)?
4. **Truth in the UI.** The Inspector line must come from catalog.sqlite, never the map or a record field; a poisoned key must show Unknown (never another role) and never crash; "Role: …" while reading, never a guess. Is "set by Rick" honest given the table has no decider column (policy: only Rick sets a role; the only writer is a person's menu click)?
5. **Migration.** Additive only; an older build refuses version 13; the ladder 7 → 13 lands with both versions agreeing; a file holding a CHECK-violating role row is refused at open (integrity_check) rather than opened.
6. **The label change is display-only.** No stored `ArchiveStage` value, enum case, rule key (`stage: Master` in the Angel policy JSON) or comparison changed; search still finds everything it found before.

**Evidence already run:** RED seen for the label (5/5 red, 8 issues → green), tables in the commit messages; production-shape migration on a sqlite `.backup` copy of the 2026-10-25 catalog (6,593 contents / 23,059 files): 12 → 13, every table count unchanged, integrity ok, FK check 0; counts in the commit messages and the hand-off report.

**Known and accepted (do not report):** GRDBCatalogRepository.swift over SwiftLint file length (pre-existing); the Angel rule language keeps the key `masterAssigned`; suggestions and the rejected-suggestion veto are a later, separate approval; the CSV's FADGI/PBCore column is not built yet; Original (carrier) is not stored yet.

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside these files.
