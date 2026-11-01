# Codex review — Provenance Set Role — closing pass

- Range: `main..feat/provenance-set-role`
- Credits spent: unavailable
- Tokens: 105570
- Finding count: 0
- Verdict: merge — F1 and F2 are closed; no new data-loss or truth risks found in the scoped review.
- Run: 2026-10-27T00:34:14Z (cycle #157, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0  
Verdict: merge — F1 and F2 are closed; no new data-loss or truth risks found in the scoped review.

Verified `80f4ba155..e0fa3067a`:

- **F1:** SQL determines changed/unchanged for every selected digest; read-back refreshes all selected entries; commit/attach epochs reject stale load snapshots.
- **F2:** Inspector results carry their digest and completed revision; mismatches show “Role: …”.

**41 tests passed:** 13 Core tests using `--skip-build`, plus 28 rebuilt Debug app tests, including all five new regressions. No source edits; worktree clean.

| Scoped file | Result |
|---|---|
| `Store/CatalogProvenanceRolesSchema.swift` | read, no findings |
| `Store/CatalogProvenanceRoleRows.swift` | read, no findings |
| `Store/GRDBCatalogRepository+ProvenanceRoles.swift` | read, no findings |
| `Store/GRDBCatalogRepository.swift` — migration registration | read, no findings |
| `Store/CatalogRepository.swift` — protocol composition | read, no findings |
| `Provenance/ProvenanceRoleStore.swift` | read, no findings |
| `Provenance/ProvenanceMenu.swift` | read, no findings |
| `Provenance/InspectorProvenanceRoleLine.swift` | read, no findings |
| `Catalog/CatalogCommitter.swift` — specified case | read, no findings |
| `Catalog/CatalogAuthorityFlip.swift` — attach lines | read, no findings |
| `ModelsUI/ArchiveModels+Presentation.swift` — `displayName` | read, no findings |
| `docs/design/catalog_sqlite_schema_v1.sql` §17 | read, no findings |
| `VideoScanCoreTests/Store/CatalogProvenanceRolesTests.swift` | read, no findings |
| `VideoScanTests/ProvenanceSetRoleTests.swift` | read, no findings |
| `VideoScanTests/ArchiveStageArchivedLabelTests.swift` | read, no findings |

## Brief

**Closing pass on YOUR cycle (docs/reviews/codex/codex-review-provenance-set-role-2026-10-26.md, fix/2).** Fixed in `e0fa3067a`: F1 — `set` decides changed/unchanged only inside the transaction from SQLite for every selected digest; in-tx read-back refreshes every selected digest; `load()` generation-stamped (`apply(rows, takenAt:)`), older snapshots never applied. F2 — readings carry their digest; the view stores (digest, revision) with the result and shows "Role: …" otherwise. Known trade-off (do not report): an all-unchanged selection commits one empty generation. Verify both closed (focus `80f4ba155..e0fa3067a`); new findings only if data-loss or truth risks.

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
