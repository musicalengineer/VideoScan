# Remote use — LAN Mac first, iPad second, web portal late September

**Status:** PROPOSED 2026-08-29 (Rick's priority order). Design before code. Reviewer: codex.

## What exists
- `CatalogSync` (master/viewer by hostname): master = M4 writes `manifest.sha256` after every save; viewer rsyncs `catalog.json` + `POI/` over SSH into staging, verifies SHA-256, atomically swaps; viewer `CatalogStore` is read-only; auto-refresh polling.
- Hallie web server on the master (port 8765): chat + media playback to iPad/browser; `HallieWebProxy`/`HallieWebBridge`.
- Compiled family-tree artifact (16 MB, codec 4) + `People/<ID>/` enrichments live in App Support on the master.
- Privacy model: read for any authorized family member, write = Rick (admin).

## Phase 1 — another Mac on the LAN (HIGHEST)
Goal: launch VideoScan on the M1/M5, see the same catalog, tree, people, photos, ask Hallie, play media. No writes.
1. **Sync scope**: add `family-tree/compiled/` (current generation + pointer), `People/`, `family-tree/originals` sidecars, CyberBrain store, and the attestation ledger to the viewer allow-list; keep manifest verification; the viewer never recompiles (a stale/absent generation shows the Recompile banner as "compiled on the master — sync again").
2. **Media playback**: catalog paths are master-local (`/Volumes/FamilyArchive/…`). Two modes, chosen per volume: (a) **stream from the master** via the existing web playback endpoint (works everywhere, no mounts, HTTP range requests, AVPlayer plays it); (b) **SMB mount with path mapping** (`VolumeStatusCache` learns `/Volumes/FamilyArchive` → `smb://ricksm4.local/FamilyArchive`) for full-quality scrubbing. Default (a); (b) opt-in per volume.
3. **Hallie on the viewer**: the viewer's chat talks to the master's Hallie web bridge (same answers, same logs, the model runs where it runs today); fall back to a local model only if the master is unreachable and a local brain is installed. Voice stays local to the viewer.
4. **UI**: viewer mode hides master-only actions (scan, ingest, pull, edit kinship, dispositions, delete) or shows them disabled with "on the master (RicksM4)". Status chip: "Viewing RicksM4's catalog · synced 2 min ago".
5. **Tests**: viewer-mode isolation (poisoned App Support), sync allow-list round-trip with manifest, path-mapping matrix, stream vs mount fallback, Hallie proxy parity (same transcript both ends), read-only enforcement for every write path (sensor across all 12 MFO kinds + kinship/notes).

## Phase 2 — iPad: browse + Hallie (Safari/PWA, no App Store)
Extend the existing web pages: catalog browse (search/filter/sort read-only), person pages (tree card + photos), Hallie chat with playback (exists). Same bridge as Phase 1 item 3, so nothing forks.

## Phase 3 — web portal (late September)
Family-facing read portal outside the LAN: auth (invite links / passkeys), TLS, per-viewer audit log; reuse Phase 2 pages; Publish pipeline (per-asset + in/out segments) feeds it. Contemporary people never leave the LAN unless Rick publishes.

## Open questions for Rick
- ANSWERED 8/29 16:05: the M5 (porch) first. Media: stream from the M4 by default, SMB opt-in.
- Should the viewer be allowed *notes* (archivist notes, dispositions) queued back to the master, or strictly read-only in Phase 1 (recommended: read-only)?
