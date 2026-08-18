# Runbook log — 2026-08-18 catalog clean-up after redistribution

Interleaved: 🖥 Rick in the app (Release build, main 9cbae327) · ⌨️ Claude in the shell.
App-side evidence: `~/Library/Logs/VideoScan/{videoscan,catalog,relocate}.log`; catalog snapshots in `~/Library/Application Support/VideoScan/`.

## Baseline (⌨️ 13:30)
- catalog.json: 8,404 records; 1,363 dangling (78 GB) on mounted volumes.
- /Volumes/Projects: 679 media files / 1.8 TB, ZERO catalog records (Finder copies of osx10.8_backup 351 GB and MediaExpansion staging 1.3 TB).
- MXF: 2,014 files / 1,034 GB; only 22 files / 11 GB present in >1 tree.

## 1a 🖥 Update Catalog → CrucialX9 (14:27–14:28)
- Tripwire fired (1,091 of 1,510 > 50 & > 20%); snapshot `catalog.pre-merge.2026-08-18T18-27-53Z.json`; 1,091 pruned (may5/, output_may3/ experiment outputs).
- After: 7,313 records; CrucialX9 419 / 0 missing; dangling 272.
- NOTE: prune landed in a plain scan merge 9 s before the Update Catalog preview reported "0 missing" — verify whether Preview committed instead of parking (possible bug; check before relying on 4b).

## 1b ⌨️ scripts/catalog_purge_dangling.py --apply (14:30, app quit)
- 194 records under LaCie CheesegraterArchive/{InternalRaid 87, osx10.8_backup 85, highsierra_rickb 22}; all files absent; 0 with ★≥2.
- Written gen 199; snapshot `catalog.pre-danglingpurge.2026-08-18T18-30-48Z.json`.
- After: 7,119 records; dangling 78 (26 Donna_clips → step 2b; rest reviewed after step 3).

## 2a 🖥 Migrate osx10.8_backup (LaCie) → /Volumes/Projects/osx10.8_backup
- Reconcile preview: 288 classified · 3 copy · 263 adopt (already at dest) · 20 safely-redundant (mark deleted w/ witness).
- ⌨️ verified: all 23 non-adopts exist on LaCie; Finder copy had skipped rickb/Movies/. Witnesses for the 20: from-Mini2TB 12, MediaExpansion/MoviesExpansion 6, ~/Movies 1, LaCie other 1. The 3 copies: DSCN0359.AVI, divx splash .part, playbutton798x450.mov.
- Apply (14:38–14:41): succeeded=3 adopted=263 safelyRedundant=20, 96.7 MB copied, 155.8 s (reconcile hashing dominates).
- ⌨️ verified gen 202: 266 records on /Volumes/Projects/osx10.8_backup, all with originalFullPath, all present; 20 LaCie records = Manually Deleted (witnesses in relocate.log). 7,119 records; dangling 78.
- Filed GH #162: Reconcile PREVIEW writes nothing to relocate.log.

## 2b 🖥 Migrate /Volumes/MediaExpansion → /Volumes/Projects/_staging_from_MediaExpansion
- (pending)
