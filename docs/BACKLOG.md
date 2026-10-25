# Backlog — parked, one line each

*Where ideas go so they are not lost and not in the working context. Add a line (or a GH issue labelled `idea`); never a design doc until Rick says "design it". When a line becomes the week's theme it moves to `STATUS.md`; when built or dropped it is deleted here. Seeded 2026-10-23 from the design docs (most now retired to git history; see `docs/archive/INDEX-2026-10-reset.md`); `#NNN` = GitHub issue; `(ruling)` = waits on Rick.*

## Rulings that gate several items (from the October retrospective §5)
- (ruling) Q1 Which feature list is current — `project_goals.md` ranks dedup 3rd; the 10/18 tab list omits it.
- (ruling) Q2 Events: is the Event Analyzer the one engine, with the Steward lane and Angel labels folded in?
- (ruling) Q3 Family Tree coupling: separate package / separate app / in-process (a read model is needed either way).
- (ruling) Q4 Dedup/pruning: fold Excess copies + PrunePlan into Cleanup and delete PrunePlan, or redo with a typed verdict.
- (ruling) Q5 Quarantine door: manual Rejoin, or history only (#339; 268 rows may be real files on offline drives).
- (ruling) Q7 Hallie: detach behind a read model, or stay in-process and shed voice/web/shell.
- (ruling) Q8 Archive Angel: keep as recommender, shrink to "Ready" badges, or cut.
- (ruling) Q9 People engines: freeze at Vision + native Find & Tag, or cut further (POI search is no longer the strategy).
- (ruling) Q10 Folders: one grouping engine or two; folder kinds; may confirmed events overlap?
- (ruling) Q11 Model split: which store first (suggested: scan/merge pipeline) and the six §6 guard-rail decisions.
- (ruling) Is the family viewer (read-only, a cousin or grandchild) still a 2026–27 goal that shapes what we keep?

## Catalog store
- Step G: sidecars → tables (catalog-audit, fullhash marker, ignored-content, events decisions, ledger rows, integrity runs); then delete `CatalogStore`, `CatalogSnapshot`, `CatalogLock`, `LiveReload`, the Codable DTO layer, `JSONCatalogRepository`, Core `Import/` (decided 10/20).
- H′: `CatalogSync` ships a sealed `VACUUM INTO` copy to viewer Macs (viewers frozen at the 10/18 JSON; previewsweepd and the Hallie shell still read it).
- Quarantine screen listing rows with their words (#339). (ruling Q5)
- #338 near-full disk raises high-water before COMMIT → misleading read-only reopen; verify #340 fix landed (refused SQLite launch un-froze catalog.json).
- Stop decoding the 80 MB catalog.json and rewriting `.prev` on every launch (`CatalogAuthorityFlip`).
- Store hardening tests: two writers (headless `--audit-catalog` vs app, #323); `VACUUM INTO` before any migration; a copy taken while the app runs (WAL).
- Retire the three save wrappers (~150 sites) for `markChanged` so the model knows which row changed instead of hashing every row.
- Stat-stamp fast path on rescan, only if Codex clears it.
- Internal-drive audit stamp (93 internal files land in quarantine until the first rescan).
- (ruling) Copies disagreeing within the 2 s window: keep both + conflict flag (today) or latest wins; reject-vs-confirm of one person on two copies.
- (ruling) Roles of `isPlayable`, `masterLocation`, `backupDestinations`, `workspaceActive`, `needsReformat`.
- Export bundle (`.videoscanbundle`) must carry catalog.sqlite, not catalog.json.

## Integrity and truth
- Verify Catalog tiers 2–4: rolling fixity re-read (1/30 per night), decode-to-end, derived stamps carry the digest; weekly deep pass.
- Weekly restore test: load the latest backup read-only in a sandbox, compare counts to live.
- Every catalog writer's OUTCOME line: rows before · after · where the difference went.
- Finish the FileFact surface audit: Compare Media band, folder relation words, Catalog columns, inspector, Catalog Status rows; a sensor per surface.
- Audit Archive weekly deep pass: fixity + decode-to-end + codec-risk table.
- Fix Links review sheet (group by vanished folder; digest → Spotlight name+size; Relink / Merge / Mark missing / Leave); never rescan to fix a hole (#326).
- Scanner stops cataloguing through symlinks (#326).
- Tier 0 nightly headless when the app is closed, plus the reciprocal launch check (#323).
- Monthly Verify Archive Copies and one ClamAV pass (NDSA Integrity 0 → 1).
- Nightly adversarial confirm step must build at the reviewed head, not current main (#247).

## Provenance (top of mind)
- Phase 1: schema v13 additive — `capture_setups`, `carriers`, `capture_events`, `carrier_spans`, `file_provenance`, `provenance_assertions` with the rejected-veto trigger.
- Phase 1: Triage ▸ "Needs provenance" filter + Provenance sheet grouped by proposed tape; Confirm tape confirms every field; July VHS backfill from folder + encoder + birth date (the 720×480 rule matches zero July files).
- Phase 2: Promote gate hard on role + carrier-or-born-digital, "archive with provenance unknown" override with reason; nudges for setup/videographer/condition.
- Phase 2: regenerate `00_Index/Provenance.csv`, `Carriers.csv`, `Provenance_README.txt` under the index lock; ledger kinds `carrierInspected / captured / provenanceConfirmed / transferSuperseded` appended.
- Carrier inspection step, once per cassette (60 s), before capture.
- Phase 3: "New captures" nudge; H.264 viewing proxy made at ingest so FFV1 masters skim and seek in-app.
- dvrescue per-frame recording dates for the 30 DV masters (biggest free dating win).
- (ruling) The four open questions: Provenance.csv vs manifest v4 (deep dive says CSV); role vocabulary (ours vs PBCore generations); hard vs soft gate the first month; the July device-chain line.
- (ruling) Re-digitize the kept tapes natively (10-bit 4:2:2) as a second capture event; does a confirmed better re-capture supersede the July FFV1 masters?
- Later: PBCore XML export; QCTools/MediaConch post-capture QC.
- (idea, Rick 2026-10-25) Catalog right-click **Provenance ▸** {Find Master, Find Similar Footage, Find Duplicates, Find Best/Repaired Version} — ONE door to engines that exist (lineage/archive copies, footage likeness, duplicate groups, Events pick-the-master); phased; a per-file provenance score (option 3: grade and work up the chain, never a catalog restart) comes after the four 10/22 answers.

## Events, Compare Media, segments
- Events page gets the Compare Media verdict band + two spools per suggested group ("same occasion or different years?" pre-answered); constellation view.
- Fold the Streams table and Compare Footage into Compare Media.
- New evidence lines, no new rungs: video barcode for silent footage, SigLIP 2 scene words, speaker similarity.
- (ruling) Rung 4 "recorded at the same time": auto-merge two suggestions or only pre-answer.
- Events v1.1: in-file ranges on the decision key (segments arrive without migration).
- Derived-date previews through the existing date action once membership review works.
- Recover existing human organization as sourced claims: Avid bins, FCP projects, tape labels, dated photos.
- Rare-phrase / matching-audio search for the other camera angle or an excerpt's source tape.
- Recurring locations as context not identity; music as an activity family; birthday + spoken age → candidate year.
- (ruling) Event categories beyond the nine; dismiss semantics; Open = QuickTime or in-app seek.
- (ruling) Cloud use on derived text (captions/transcripts) for later labelling, or local only.
- Bounded retrieval experiment: rules vs SigLIP 2 vs Qwen3-VL-Embedding-2B on held-out occasions, split by occasion and lineage.
- "Same / different / uncertain occasion" as a first-class correction exported as versioned examples.
- Re-run Whisper for segment timestamps on FamilyArchive (~21 machine-hours); retain segment timing.
- "Share text across copies" cycler (captions/transcript/OCR by content identity, with provenance).
- Analyzer START/OUTCOME report lifecycle exclusions; sensor: an eligible archived video with no text after a full pass fails.
- (ruling) Segments / "Moments": content-keyed time ranges with tags, one-keystroke in/out, machine-proposed boundaries; eleven decisions open.
- Analyze the archive master if it decodes, else the smallest access copy; flag the 28 `videoUnreadable` records `needsReformat`.
- (ruling) Steward trial pane: fold into Events/Analyzer or cut (Q2).

## Cleanup, pruning, removal lanes
- (ruling Q4) PrunePlan: R1–R5 + "no obvious choices"; delete `PrunePlan.swift` and the ImportanceBar (−3,800 lines); default-check identical copies vs a "Keep one working copy" toggle; attestations advice-only.
- Retire Archive ▸ Excess copies once Cleanup's archive-held-copies lane is proven.
- New Cleanup lanes from Compare Media: "clips of a master" (R2) and "superseded transfers" (R3), proving at the move.
- Delete Duplicates' per-file turn becomes a `RemovalStep` inside the one trash engine; MFO wrapper for batches over ~1 min.
- Scan merge's active-gone prune → `.missing` marker (tripwire semantics); Retire's "Forget volume records" as row removal vs marker.
- (ruling) Clear the 959 legacy "manually deleted" labels.
- #259 duplicate detector over-claims same-size re-exports; remember refusals; Reclaim numbers inflated.
- Archive-internal cleanup of redundant versions (keep: original + preservation + access + edit), per-item OK; the invariants need amending to match (DECISIONS contradiction 4).
- Only-copy badge in Triage/Catalog; codec ladder table; DRM movies suggested "not family media".
- "Interesting family video" score for Triage ranking (duration, people present, not a transition/test pattern) — a RANKING, never a scan gate: measured 2026-10-25, 7,506 of 11,468 live rows are under 30 s and 649 of those Rick marked Important, so duration alone is not junk evidence.
- Run MediaAnalyzer scoring on scan (today it runs only from Triage's Analyze button) — policy change, Rick's call.
- (ruling) Delete `ArchiveRefile` (predecessor of Update…).

## Catalog UI and folders
- Folders, next in order: drag files onto a folder, rename, remove (ungroup, files stay), person folders (green), other (grey); relax exclusive events for person folders.
- Sound relation `⊂` clip-of within an event; pairwise audio match cached per event.
- Promote from a folder member offers archive-original / retire-original / remove-other-copies through Cleanup lanes.
- Move Triage's ~6,200 lines out of `Catalog/`.
- Tab-charter cleanup umbrella #155: 26 misplaced features, one door per shared action.
- Repair… one engine (#121): Combine, Balance, Rebuild, Clean Up, Reformat as recipes.

## Archive
- Off-site copy, verifiable: "Export critical set" (BagIt + checksums), off-site/cloud tracked per archive file (#249, target 2026-11-01).
- #294 identity drift (17 archived rows read Not Yet Archived, 60 dangling lineage, stale manifest ids) · #286 promote/refile hardening · #221 inspector date edit on an archived record opens Update… · #280 access copies for archived originals · #170 archive portability / Adopt on the Ultra.
- Portable archive a family can read without VideoScan: `Provenance_README` / Living Will stewardship page.
- Original-footage classification (camera / tape / slideshow / screen recording), reversible and human-correctable.

## Model split and code health
- (ruling Q11) VSM split slices 0–9: guard-rail sensor (≤134 extensions, ≤90 @Published), PreviewService ✓, ScanStore, RelocateQueue, NavigationStore, ArchiveStore, DuplicateJobs, change bus replacing `records.didSet`, RemovalStore, CatalogStore.
- Activity enum replacing the Bool flag soup (needs a table of flag combinations first).
- Dead code: ~7,500 removable lines (Periphery 10/11) after Rick's call.
- CCN > 30 to zero before the Ultra (#281); switch/else-if census → typed enums.
- Remove concurrency escape hatches as stores leave the model.
- Core helper `[T].parallelInitialized(count:chunk:)` so the four copies of the disjoint-chunk `nonisolated(unsafe) let slots` proof (FamilyTreeNameSearch, CatalogChangeDetector, FamilyTreeLiveModel.sidebarRows, FamilyAssetIdentityDirectory) become one audited site (reviewer, 10/25).
- Long operations not yet MFO jobs: FamilySearch pull/refresh, RescueFileCopier, Angel sweep, Angel buffer Clear (#242).
- Background Activity panel = the Analyze cycler control panel (#195).
- Test quality: sensors prove execution not presence (#262); integration ladder rungs 1–3 (#140); #273 main-thread SIGSEGVs; test hosts writing to the real `.trash` (#256).
- `tools/codex_review.py`: write the brief and verdict to `.scratch/` and the PR instead of `docs/reviews/`; `tools/engineering-room/` is dead code since 10/02.
- Pin `.claude/scripts/session_start.sh`'s lane lines with a test (the retired morning-line tests covered the old hook).

## Archive Angel (all hang on Q8)
- Consolidate to one rule set and façade; wise-design stages 4–7; curation phases (fatigue, "New to you", the wings-and-bell reward); `default:` arms that swallow new floors (C07 plan); #231 Angel Checks gates stale across an await.

## People (Q9), Family Tree, Hallie (Q7)
- People: move clip compilation to a future "Create" window; #84 merge two profiles; #133 People column/tags reliability; a rejected tag must never be re-proposed (the FamilyTagging bug the provenance trigger fixes for its own tables).
- Family Tree: family map stage 3 (year slider) and 4 (flags, #229); Record Finder Phase C + UK adapters; common-ancestor precompute into CyberBrain; #188 one invalid CyberBrain locator disables the whole brain; parked: Story of the Day (#236), Life & Times 2–3 (#238), period nicknames (#243), interval inference (#216).
- Hallie: agent lane + E1 harness (cloud model in a bounded tool loop, Swift verifier, data-class gate); compound/filter/count queries (QueryAST v3); family web access read-only (#244) and iPad browse (#42) gated on the family-viewer ruling.

## Storage, dates, improve
- Volumes come and go (#169): auto-resume on remount, wake-on-LAN / SMB auto-mount; #164 cancel mid-walk must not save a partial checkpoint as complete; fold the ⌘⇧V Volumes window into Storage; #189 UUID reads on main beachball on a hung share.
- Dates: #118 plausibility gate (demote transfer dates on digitized tapes); #209 donor edit re-dates shared copies without relaunch; undo sidecar for the retriangulation pass.
- Improve (Nov–Dec): QTGMC/VapourSynth restoration, local upscale/interpolation (#299); Trim (#154); A/V sync check on improved versions (#309).

## Process and tooling
- GH issue triage close script (31 done + 16 obsolete + 1 dup; 47 → 23 umbrellas) awaiting Rick's OK.
- Post-cutover stability baseline (the 10/14 one predates SQLite).
- End-of-October Codex spend review; spend the remaining cloud credit before 2026-11-05.
- Log retention prune job (#199); metrics page down to a few vital signs (#310).
- Adversarial 10/18 findings #4–#7 (deferred to the Import removal): close with pinning tests or decline with reasons.
- Fleet roles on the Ultra: a resource plan (cores/RAM per job, weekly calendar), not just a role list.

- Metrics board: a per-file "Swift 6 warnings" column straight from `scripts/warnings_baseline.tsv`, and watch CCN / grades across the migration (Rick 10/25; stage 2 of `docs/design/swift6_migration_2026_10_25.md`).

## Docs still to write (when their subject is live)
Catalog schema and commit model for readers (replaces `database_design.md`; carry its POI layout, bundle contents and recovery runbook) · MFO job lifecycle and how to add a job · the removal lanes today and the one-engine target · Archive Angel: what stays (after Q8) · Family Tree read model (after Q3) · splitting `VideoScanModel` (after Q11) · family viewer mode · P0 retrospective: how integrity fell off the table · final provenance design after Rick's four rulings · post-cutover stability baseline · segments decision record.
