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
- (idea, Rick 2026-10-25) Catalog right-click **Provenance ▸** {Find Master, Find Similar Footage, Find Duplicates, Find Best/Repaired Version} — ONE door to engines that exist (lineage/archive copies, footage likeness, duplicate groups, Events pick-the-master); phased; a per-file provenance score (option 3: grade and work up the chain, never a catalog restart) comes after the four 10/22 answers. → **Provenance Grade** (auto-generated, per file, evidence-only): #396 (Rick 2026-10-29).

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
- Video LLM: frozen local VLM + structured scene JSON → assertions (era claim, place_signature); era benchmark and 18-event retrieval test first, LoRA only on extraction errors. `docs/research/video_llm_for_family_media_2026-10-29.md`.
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
- CCN worst offenders after 2026-10-25 (isWorthRestoring 36→7, executePresenceLike 44→5 done): next by nightly measure — `HallieLineageQuestion.detectShape` 42, `POIStorage.migrateToUUIDFoldersIfNeeded` 42 (POI frozen; retire instead), `HallieTurnExecutor.execute` 41, `ArchiveAngelSweep.perform` 39, `ArchiveAngelJob.selectFromEvidence` 39, `ArchiveAngelJob.prepare` 37, `ArchiveAngelPromoter.promote` 35 (rule 10 → Codex).
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
- Hallie's brain placement (Rick 2026-10-27, investigating): bigger model on the M4 served to the Ultra over the Thunderbolt Bridge, vs. a huge model on the Ultra (96 GB) as an experiment. Today: Ultra local first (`archivist.ollamaHosts`); code `OllamaEndpoints.defaultHosts` still M4-first.
- Hallie presence (reviewer 2026-10-25, pinned as-is by `HalliePresenceLikeCharacterizationTests.treeOnlyKinshipRebindsThePersonButKeepsTheKinWord`): a GEDCOM-only resolution of "my dad" keeps `dad` as a content word so the answer relaxes instead of listing Dad's videos; the People-tab path marks the kin word spent. Intended or a gap? Also: `retryUntaggedNamesAsWords` takes 8 parameters — a request struct; and the Hallie characterization file sits in the gauntlet unit stage while its siblings are in `hallie` (a manifest move).
- People: move clip compilation to a future "Create" window; #84 merge two profiles; #133 People column/tags reliability; a rejected tag must never be re-proposed (the FamilyTagging bug the provenance trigger fixes for its own tables).
- Family Tree: family map stage 3 (year slider) and 4 (flags, #229); Record Finder Phase C + UK adapters; common-ancestor precompute into CyberBrain; #188 one invalid CyberBrain locator disables the whole brain; parked: Story of the Day (#236), Life & Times 2–3 (#238), period nicknames (#243), interval inference (#216).
- Hallie: agent lane + E1 harness (cloud model in a bounded tool loop, Swift verifier, data-class gate); compound/filter/count queries (QueryAST v3); family web access read-only (#244) and iPad browse (#42) gated on the family-viewer ruling.

## Storage, dates, improve
- Volumes come and go (#169): auto-resume on remount, wake-on-LAN / SMB auto-mount; #164 cancel mid-walk must not save a partial checkpoint as complete; fold the ⌘⇧V Volumes window into Storage; #189 UUID reads on main beachball on a hung share.
- Dates: #118 plausibility gate (demote transfer dates on digitized tapes); #209 donor edit re-dates shared copies without relaunch; undo sidecar for the retriangulation pass.
- Improve (Nov–Dec): QTGMC/VapourSynth restoration, local upscale/interpolation (#299); Trim (#154); A/V sync check on improved versions (#309).

## Process and tooling
- UPS wattage menu-bar app (Rick 2026-10-27): PowerPanel Personal is Intel-only and its service hangs ("Service Not Ready", port 31111 closed). Tiny native Swift app: IOHIDManager on the CyberPower CP1500PFCRM2U (0764:0601, HID Power Device page 0x84), read PercentLoad/ActivePower, show watts in the menu bar; non-exclusive read so macOS's built-in UPS shutdown keeps working (verify on the unit). Alternative: Homebrew `nut` (arm64, installed 2026-10-27; config in /opt/homebrew/etc/nut): `macosx-ups` (no root) gives charge/runtime/status but NO load; `usbhid-ups` needs root — test `sudo …/usbhid-ups -a cp1500 -d 1 -u root` decides whether it can share the device with powerd. Goal (Rick): live watts + log every ~60 s (SQLite) → weekly and monthly average watts and kWh for everything on the UPS (Ultra, M4, Pegasus, LaCie, displays). Just for fun; skip third-party NUT clients.
- Ultra move follow-ups (2026-10-27): `migrate_data.sh` skips app preferences (Storage list, dup-keep precedence, scan options lived only there); `install.sh` prints "ready" after a stopped preflight; `TimingBudget` treats all 30 Ultra cores as equal (10 Super + 20 Performance) so a busy run reads as quiet → strict false reds; TreeWalkScale wall-clock flake (work 1.0 s, wall 24.6 s at load 42/16); M4's nightly role as headless test host; code defaults `defaultMasterHostname` → RicksUltra.local once declared.
- Swift 6 test-host crash follow-ups (2026-10-25, fix 2ab067d62): confirm `MasterArchivePromoteTests.swift:350` (`var poisoned` mutated in a `progress:` closure) is called on the test's own thread; `nonisolated(unsafe) var` on a CAPTURED LOCAL does not silence the runtime isolation check (BoundaryAuthorization crashed with it); `-test-iterations N` does not repeat Swift Testing tests on this Xcode — repeat runs need N separate invocations.
- Test fixtures that pin `isReachable = true` on unmounted `/Volumes/...` targets (seven files besides DuplicateCodexReviewTests, `grep "isReachable = true" VideoScanTests`): the model's reachability refresh overwrites the pin at the next suspension point (the 2026-10-25 DuplicateReelectionStampTests flake). Any of them that awaits while comparing reachability-derived state has the same latent flake — fix the same way (let the target derive its own facts, or pin through `VolumeReachability`).
- GH issue triage close script (31 done + 16 obsolete + 1 dup; 47 → 23 umbrellas) awaiting Rick's OK.
- Post-cutover stability baseline (the 10/14 one predates SQLite).
- End-of-October Codex spend review; spend the remaining cloud credit before 2026-11-05.
- Log retention prune job (#199); metrics page down to a few vital signs (#310).
- Adversarial 10/18 findings #4–#7 (deferred to the Import removal): close with pinning tests or decline with reasons.
- Fleet roles on the Ultra: a resource plan (cores/RAM per job, weekly calendar), not just a role list.
- Background helper looks like the app (Rick 2026-10-28): the detached Find Tag daemon is VideoScan.app in --find-tag mode, so Activity Monitor shows the same name and icon. Plan: a nested helper bundle `Contents/Helpers/VideoScan Background.app` (own name, own bundle ID, signed "VideoScan Local"; one extra Full Disk Access grant) whose icon is the app icon with a badge drawn by us, not stock art: Rick liked a "process" gear-in-circular-arrows or a checklist-with-clock badge, in a different colour. Weigh it against the single-binary design (shared TCC grants, Vision/CoreML in one binary).
- Quit stalls on a sleeping drive (2026-10-28, 24 s): RAMDisk.cleanupStaleMounts lists /Volumes, which touches every mount root; a spun-down drive (LaCieWorkspace) blocked quit 18:36:22→46. Use getmntinfo(MNT_NOWAIT) (in-memory mount table) and give `hdiutil detach` a deadline; test that the sweep never touches a mounted volume.
- SSH builds on the M4 cannot use the "VideoScan Local" key (login keychain locked over ssh → errSecInternalComponent): run_sensors.sh and other ssh-run builds pass the ad-hoc override the nightly already uses.
- Put the Ultra to work (Rick 2026-10-28: "see some silicon melt… in a productive way"): (1) A/B bigger Hallie brains (qwen2.5:72b, llama3.3:70b) on the 870-question harness, both Macs, same build; (2) a primed prefix: the family-tree summary + catalog facts as a cached long-context prefix (KV/prompt cache), facts still answered from evidence; (3) LoRA fine-tune (mlx-lm, local) for SKILL not facts: question → Hallie query, trained on the harvested corpus; weights hold family names → never in git/cloud; (4) GPU/ANE batch work: vision-LLM scene captions, Whisper segments, faces/Find Tag throughput; (5) the engines Gemini suggested (list from Rick); (6) the `.1999_maybe` stem: output names treat it as an extension.

- Metrics board: a per-file "Swift 6 warnings" column straight from `scripts/warnings_baseline.tsv`, and watch CCN / grades across the migration (Rick 10/25; stage 2 of `docs/design/swift6_migration_2026_10_25.md`).

- **Nightly UI smoke on the M4 (ruled 2026-10-28):** first unattended run 10/28 on 457d7e1b: 9/14 passed in 6 min (build 3.5 min). To make it nightly: (1) fix the 5 stale UI tests — Gauntlet02/03/04 drive the removed "Catalog Options" button (Rick names the control they should use now), CatalogKeyboard test8 wants the removed File ▸ Catalog Info, Gauntlet01 needs a synthetic non-family face fixture; (2) add a quit-and-relaunch smoke case; (3) M4 must not lock its screen overnight (XCUITest needs an unlocked session, 2026-07-20) — Rick's setting; (4) launchd UI lane before the 02:00 nightly, sharing its lock; (5) morning digest/metrics line for both Studios. Combine*UITests read the real catalog: keep them out until they use fixtures.
- **Ultra nightly fires at 05:00, not 02:00 (10/28 and 10/29):** the plist says Hour 2 (installed 10/27 20:24), the job is loaded and enabled, the Mac was awake, nothing else calls the guard. 05:00 EDT is exactly 02:00 Pacific; the Ultra was set up 10/27 and launchd has not restarted since (uptime ~1.5 days). Check after the next reboot; if it persists, `launchctl bootout`/`bootstrap` the job and compare.
- **Real-volume sensors lane (2026-10-29):** `RealVolumeWalkSensorTests` (LaCie incident directory) now runs only with `VIDEOSCAN_REAL_VOLUME_SENSORS=1`, after it hung the Ultra's 10/29 nightly for 95 min (cause unproven; guess: a removable-volume privacy prompt to a fresh test host). Give such sensors an attended or pre-granted lane (and a time limit) so they still run somewhere.
- **The M4 catalog is schema 12:** its nightly Hallie replay is "incomplete" (0/56, 0/817) because this build opens a catalog read-only only at schema 13. Refresh the M4 copy, or point the M4 replay at the Ultra over the tunnel.
- **UI tests, next increments (Rick 2026-10-29, "it is important"):** (1) ~~Gauntlet flow 6+: open the Family Map~~ built on `test/ui-family-map`: flow 7 (`Gauntlet07FamilyMapUITests`) behind the `-gauntletFamilyTreeDir` seam and the synthetic `GauntletFamilyTreeFixture`; (2) ~~one repo script~~ built there too: `scripts/m4_run.sh ui|deep|all|status [--host m4|ultra]` (watchdog per plan, lock, `status` summary; the Ultra path is untested until Rick's screen is free; the design's verdict JSON, commit range and `refs/m4run/green` are still to do); (3) the Ultra's UI test builds are ad-hoc signed, so every rebuild re-asks for drive access; sign them with "VideoScan Local" so one Allow sticks (the M4 has no external drives, so it needs nothing). The Ultra now needs no password for Automation Mode (Rick ran `automationmodetool enable-automationmode-without-authentication` and `DevToolsSecurity -enable`, 10/29).
- **Hallie model host is per-run:** the harness on the Ultra can use the M4's model over an ssh tunnel (`--host`), so model A/B runs need no catalog copy on the M4.

- **Hallie benchmark 2026-10-28 follow-ups:** (1) harvest new live questions automatically from BOTH Macs at the nightly (`hallie_harvest_queries.py` is manual; last harvest 10/10; Rick's 10/10–10/27 chats are in the M4's logs) and show "N new questions waiting" in the morning metrics; (2) log per-turn latency in ms in the Hallie turn log so the harness reports median/p90 per question (timestamps are whole seconds); (3) Ollama differs: M4 0.40.12, Ultra 0.40.11 — align before host comparisons; (4) qwen3.8:27b-mlx scores 654/803 on the Ultra twice but 619/626 on the M4, while llama3.3:70b (llama.cpp) scores 604 on both — hypothesis: MLX numerics differ by chip generation; test by running the GGUF qwen build on both; (5) CyberBrain record for Dad Breen points at a stale Ancestry id (`@I342486893646@`) absent from the merged tree — every CyberBrain→tree link for him is broken (Rick's data call); (6) a CyberBrain exact alias "Dad" plus a stale pointer would still fall through to the tree name lookup — guard in `resolveDetailed`; (7) Rick to rule: strict-042 (why a photo is possible — unbuilt) and strict-045 ("how old was Dad" sometimes answered with the date only) were moved to advisory as model-dependent; keep there or pin red in strict.

## Docs still to write (when their subject is live)
Catalog schema and commit model for readers (replaces `database_design.md`; carry its POI layout, bundle contents and recovery runbook) · MFO job lifecycle and how to add a job · the removal lanes today and the one-engine target · Archive Angel: what stays (after Q8) · Family Tree read model (after Q3) · splitting `VideoScanModel` (after Q11) · family viewer mode · P0 retrospective: how integrity fell off the table · final provenance design after Rick's four rulings · post-cutover stability baseline · segments decision record.
- M4 real-media testbed (Rick 2026-10-28): (1) an old SSD on the M4 holding a curated, expendable partial copy of real family media (every format and every known-awkward case, e.g. raw DV with one-sided sound), marked as a testbed by a marker file; automated tests may WRITE only to a marked testbed (promote, trash, relocate, repair on real media), never anywhere else; never in git, never to a cloud model. (2) The M4 as a read-only viewer of the Ultra's FamilyArchive over file sharing on the Thunderbolt bridge (viewer mode exists; check its speed and the network-volume privacy grant). (3) Overnight UI testing on the M4 against (1): a scripted run that drives every menu item in a copy of the catalog and reports what broke.
- M4 catalog fault-injection testbed (Rick 10/26): the M4 keeps (1) a continuously synced backup of catalog.sqlite (315 MB today; the viewer's sealed copy may already be it) and (2) a nightly fresh `.backup` copy that a fault suite attacks at production scale — torn/truncated pages, flipped bytes, missing or stale -wal/-shm, FK violations, newer schema, full disk, read-only folder, kill -9 mid-commit — asserting every case is refused in words or recovered, never silent loss. Never in git; stays on the M4.
