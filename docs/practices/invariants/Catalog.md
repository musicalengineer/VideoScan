---
tier: data-risk
paths:
  - VideoScan/VideoScan/Catalog/CatalogStore.swift
  - VideoScan/VideoScan/Catalog/CatalogVersionPauseBanner.swift
  - VideoScan/VideoScan/Catalog/VideoScanModel+LiveReload.swift
  - VideoScan/VideoScan/Catalog/VideoScanModel+RescanPreservation.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/CatalogUnknownFields.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord+Codable.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord+Clone.swift
  - VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecordDTO.swift
---
# Catalog file (catalog.json): versions, unknown keys, newer catalogs

Rick, 2026-10-02 (GH #167): "make sure we don't run into forward/backward
compat issues, so we don't need to be psychotic about it, just polite."

## Invariants
1. **CAT-1** Nothing a newer build wrote is silently lost. Every JSON key this build does not know — at the top level of catalog.json or inside a record, nested values included — is kept verbatim (`unknownFields`) and written back on every save path (live save, async, acknowledged, safety snapshots), carried through a rescan's record replacement, and merged forward by the live reload.
2. **CAT-2** An unknown key never overrides a known field. Capture skips every key in `VideoRecord.persistedKeyNames` / `CatalogSnapshot.topLevelKeyNames`; emit skips them again, so a known field is only ever written from its typed property and the top-level `version` / `generation` stamps stay first and single.
3. **CAT-3** A catalog written by a newer build (its `version` > `CatalogSnapshot.currentVersion`) is read-only, never an error and never a downgrade: its records are shown for browsing, catalog.json and catalog.json.prev get zero bytes (no rotation), every save and snapshot path refuses, the app shows the "saving is paused" banner and reads as read-only, and background jobs that would save are held and say so (once). This holds when the newer file is found at load, when it cannot even be decoded (no fallback to .prev with writes on), and when it appears mid-session (the write path probes the version before writing, and the store's one-shot `onNewerCatalogLatched` flips the model's banner and `isReadOnly` on that same refused save). While paused, the ONLY files that may change beside catalog.json are the refusal journal (`catalog-write-errors.jsonl`) and the advisory `catalog.lock`; no .prev rotation, no `catalog.generation.max` bump, no pre-* snapshot, no notes-repair marker (pinned by `CatalogNewerVersionNoWritePathTests`).
4. **CAT-4** When to bump `CatalogSnapshot.currentVersion`: ONLY when an existing field's MEANING or TYPE changes, or a field is removed or renamed. ADDING a field never needs a bump — CAT-1 carries it through every v7+ build untouched. The key-snapshot sensor (CatalogVersioningTests, `CatalogKeySnapshotSensorTests`) fails on any key change so the addition is a deliberate one-line edit to the snapshot, not a bump.
5. **CAT-5** Every older catalog (no version key, v1–v6) loads and upgrades in place on the next save, keeping its data; the original bytes are in catalog.json.prev after the upgrade, and a second load → save does not re-migrate (fixtures in `CatalogOlderVersionUpgradeTests`).
6. **CAT-6** Preservation is cheap: records with no unknown keys allocate nothing and encode byte-identically to before (the byte-identity goldens in CatalogStoreAsyncSaveTests); 100k records that all carry unknown keys stay inside the existing 20 s save / load budgets (Debug).
7. **CAT-7** Exactly five CatalogStore entry points reach the byte writer (`encodeAndWrite`): saveNow, saveAcknowledged, saveAsync (via `writePrecondition`) and writeSnapshot / writeSnapshotAsync (via `heldWriteRefusal`). A new write path must pass the latch; the source sensor `writeEntryPointsAreLatched` counts the call sites.

## Known and accepted (do not report)
- v7 is the first version that preserves unknown keys. Builds from before it (before 2026-10-02) still strip keys they do not know; the v6 → v7 bump is what makes the ones that check the version refuse to save a v7 catalog.
- Builds that predate the version check itself (before 2026-05-26) cannot be protected by any bump: they read and rewrite catalog.json without looking at `version`.
- Builds from 2026-05-26 to 2026-08-14 (before the write latch, dc62babf / codex #377) refuse to LOAD a newer catalog but do not latch writes, so their quit-time save can replace a v7 catalog with a near-empty one. Do not run a build from that window against a v7 catalog (flagged to Rick with the v7 bump, GH #167).
- Numbers inside unknown values round-trip by value, not by spelling: integers that fit Int64 stay integers, everything else is a Double (`1.0` may come back as `1`; a UInt64 above Int64.max loses low digits). No catalog field has that shape.
- Unknown keys are carried, not interpreted: a rescan keeps a newer build's per-record keys even if that build would have re-derived them from the file. Keeping stale data beats losing it; the newer build rewrites its own keys.
- Bundle import, catalog import and other paths that BUILD new records from foreign data are not in scope; they create records rather than round-trip the user's catalog.
