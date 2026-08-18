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
- Preview: 134 records · 3 copy (9.7 GB: avtest2.mov, Rick Breen.mov, LeavingForMontana.mov — loose files at volume root the staging copy skipped) · 130 adopt (104 mirrored + 26 moved Donna_clips) · 1 safely-redundant (FoxyRock-Piano.mov, witness = Master Archive copy on FamilyArchive).
- Apply (14:45–14:46): succeeded=3 adopted=130 safelyRedundant=1, 9.96 GB, 43.5 s. gen 205; 399 records on Projects (all present); MediaExpansion 1 (Manually Deleted, witness=FamilyArchive); dangling 52.
- Confirm-dialog wording ("Migrate 134 records 1.33 TB") counts scoped bytes, not copy bytes — fold into #162.

## (detour 14:48) 🖥 accidental rescan of MediaExpansion
- 17,719 admitted / 108 cataloged / 17,611 sniff-rejected (FCP render/peak files). Merge: 108 upserted → **107 new bare records** for files whose metadata records were just relinked to Projects. Catalog 7,226 (gen 206).
- Consequence: 107 dup groups (Projects twin has tags/provenance; MediaExpansion twin bare). Keep election in 3c must favor Projects; delete-vs-keep MediaExpansion copies = Rick's decision.

## 3a 🖥 Scan target /Volumes/Projects (whole volume) → Scan (14:51–14:59)
- 701,927 enumerated / 409,747 admitted / **956 cataloged** (387 refreshed = the relinked ones) / 359,578 sniff-rejected / 388 probe-rejected. Catalog **7,795** (gen 207); Projects 968; dangling 52.

## 3c ⌨️ Duplicate report (15:10, scratchpad/dup_groups.json; by size+partialMD5, present files only)
- 417 groups / 1,071 records / **2.17 TB** of extras. Nearly all are Rick's own redistribution copies:
  - Projects ⇄ MediaExpansion (staging: Converted_VHS 910 GB in 24 groups + MoviesExpansion 34 GB) · ~/Movies ⇄ Projects/MoviesExpansion (111 groups, 67 GB) · LaCie Pictures/Movies ⇄ Projects/MiscPhotosWithMovies+_staging_from_LaCie · Projects⇄Projects double copies (MoviesExpansion vs _staging_from_MediaExpansion/MoviesExpansion; EppyDot.mov 3×) · CrucialX9/Matt scratch copies.
- Same-volume extras (in-app Delete Duplicates can reach): **186 files / 174 GB** (Projects 145/157 GB, SanDisk 26/11 GB, CrucialX9 9/4 GB, home 5).
- **151 precedence-vs-metadata conflicts** (103 ~/Movies vs Projects, 32 CrucialX9 vs Projects, 14 CrucialX9 vs LaCie): the metadata lives on the copy precedence would delete.
- **BLOCKER for 3d:** DuplicateDetector.keeperScore ignores human metadata, volume precedence and online/offline — identical files tie → arbitrary keeper (root of 8/14 offline-strand). App dup-delete is same-volume-only + byte-verified + no carry-over. → feature/dup-keeper-precedence branch dispatched (election = precedence › metadata › technical; carry-over on delete; precedence pane). 3b/3d wait for Rick's review + rebuild.

## 4a prep ⌨️ — files to move out of /Volumes/Projects/osx10.8_backup (same volume; then 4b Update Catalog → Projects relinks)
- To `/Volumes/Projects/FromCheesegrater_10.8/`: rickb/Desktop/EP/ (Part1-3, xmas-1990-part1, EP3) · rickb/Desktop/"Sequence 1-QuickTime H.264.mov" · RickGuitar2025.MP4 (18 GB; NOTE FamilyArchive already holds 2025-xx-xx_RickGuitar2025.mov 71 GB — different file) · AvidMediaComposer/Avid Users/ChristmasDay.mov (11 GB) + MPEG/ (m2v+aiff exports) · rickb/Movies/ (Christmas2010 IMG_*.MOV etc.) · Gold_Avid-Projects (194 MB, project files).
- `Avid MediaFiles/` (MXF/99, 145 unique) → `/Volumes/Projects/AvidMedia/osx10.8_backup/Avid MediaFiles/` as a unit (step 6 home).
- Trash: rickb/Desktop/Apple_OSX_Installers (≈24 GB), rickb/Library, rickb/Music/iTunes (commercial), rest of rickb/.


## 5 ⌨️ MXF strays (osx10.8_backup/Avid MediaFiles/MXF/99) — done 15:00
- 145 files / 741 MB, all UNIQUE by (size, partialMD5) vs every other Avid tree; sidecars msmMMOB.mdb + msmFMID.pmr present. "Boston" project clips.
- Decision: keep; move the whole `Avid MediaFiles` folder as a unit into the consolidated Avid home (step 6) — same volume, `mv`, then Update Catalog relinks.
- 1a question resolved: 14:27:53 = plain committing scan from the row verb "Scan / Update Catalog"; 14:28:02 = real preview (parked). Naming collision noted on #162.

## 3c addendum ⌨️ per-source duplication (15:35) — present files, excl. Manually Deleted
| source | records | GB | dup'd elsewhere | of which w/ human metadata | unique here |
|---|---|---|---|---|---|
| /Volumes/MediaExpansion | 107 | 1329 | 105 (1287 GB) | 0 | 2 (42 GB) |
| ~/Movies | 163 | 106 | 163 | **90** | 0 |
| CrucialX9/Matt | 97 | 151 | 81 (126 GB) | **81** | 16 (25 GB) |
| CrucialX9 (all) | 419 | 505 | 101 | 100 | 318 (359 GB) |
| CrucialX10 | 50 | 427 | 7 (221 GB) | 5 | 43 (206 GB) |
| Projects/_staging_from_MediaExpansion | 133 | 1308 | 107 | 80 (adopted twins) | 26 (Donna_clips) |
| Projects/_staging_from_LaCie | 97 | 88 | 97 | 0 | 0 |
| Projects/MoviesExpansion | 184 | 119 | 166 | 0 | 18 (12 GB) |
| Projects/MiscMovies | 39 | 86 | 37 | 0 | 2 |
| Projects/MiscPhotosWithMovies | 76 | 4 | 76 | 0 | 0 |
| LaCie/Movies · Pictures · ImmichBenchmark | 19 · 76 · 16 | 83 · 4 · 19 | all | 10 · 74 · 12 | 0 |
Reading: MediaExpansion = pure staging leftover (metadata already on Projects twins). ~/Movies + CrucialX9/Matt = metadata lives on the copy precedence would delete → carry-over first. Projects/_staging_from_LaCie, MiscMovies, MiscPhotosWithMovies = LaCie originals exist, no metadata either side → precedence decides.
Branches in flight (not merged): fix/162-preview-logging (24 tests green; free-space follow-up in progress), feature/dup-keeper-precedence (in progress).

## Branches ready for Rick's review (15:55) — not merged
- `fix/162-preview-logging` (4a999bed, b8fc43d4): [PREVIEW]-tagged reconcile lines in relocate.log; Migrate button + "Bytes to copy" + free-space check use the plan's copy bytes (ready + source-moves); row verb "Scan / Update Catalog" → "Rescan". 27 tests green.
- `feature/dup-keeper-precedence` (3 commits): election = availability › Master Archive › precedence list (seed LaCieWorkspace, MediaExpansion, FamilyArchive, Projects, SanDisk, X10, X9) › human-metadata score (★ 100, people 40, notes 30, provenance 25, tags 20…) › technical › path; carry-over of human metadata onto keeper on verified delete (shared applyHumanMetadataInheritance); "Which copy do we keep?" sheet in Volumes window toolbar. 61+26 tests green; 100k election 0.73 s.
- Rick decisions on the branch: (1) offline listed volume loses to any online one (vs only retired demoted)? (2) cross-volume delete still refused by design — freeing Crucials/MediaExpansion needs a deliberate "retire staging copy" flow; (3) carry-over only on verified-identical outcome (chosen); (4) metadata weights; (6) Re-analyze needed to re-elect existing groups.

## Best-practices check (16:10) — before building the cross-volume delete
Sources: AMPAS *The Digital Dilemma* (docs/Academy_BestPractices.pdf = ~/Downloads/digital_dilemma.pdf, same doc); NDSA Levels of Preservation, PBCore asset/instantiation, PREMIS events, BagIt/MHL manifests; Kyno "Copy and Verify (offloading)" article.
Takeaways: copies ≠ duplicates (asset → instantiations by storage class: archival vs working library); redundancy is a counted policy (NDSA L1 ≥2 copies separate media, L2 3 copies one offsite); fixity = whole-file hashes verified read-after-write + periodically; deletion = staged, policy-driven, never below policy; offload tools never delete sources; the record is a portable manifest (MHL) at the destination.
Reframe adopted: "Delete Duplicates … kept copy may be on another drive" → **"Also clean up working copies"** (removes copies on <SSD> whose asset has a verified master on a more reliable drive; byte-verify; carry-over). Mechanics unchanged.
Follow-ups (not built): (a) "At risk: assets with only one copy" report from the same analysis; (b) staged deletion into per-volume `.VideoScan-Trash/` with retention; (c) Migrate writes an MHL/BagIt-style manifest at the destination; (d) Migrate verifies with the whole-file segmented content hash on both ends.
