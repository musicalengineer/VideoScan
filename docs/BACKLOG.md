# Backlog — parked, one line each

*Where ideas go so they are not lost and not in the working context. Add a line (or a GH issue labelled `idea`); never a design doc until Rick says "design it". When a line becomes the week's theme it moves to `STATUS.md`; when built or settled it moves to "Done" at the end (2026-11-01: nothing is deleted); a line longer than a sentence or two keeps its one-line summary here and its detail in `docs/archive/backlog_detail_2026_11_01.md`. Seeded 2026-10-23 from the design docs (most now retired to git history; see `docs/archive/INDEX-2026-10-reset.md`); `#NNN` = GitHub issue; `(ruling)` = waits on Rick.*

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
- H′: `CatalogSync` ships a sealed `VACUUM INTO` copy to viewer Macs (viewers frozen at the 10/18 JSON). Hallie shell and find-tag read the synced copy on a viewer since 11/04 (`CatalogAuthority.headlessSource`); previewsweepd still reads the top-level file (its launcher `PreviewService+Sweep.swift` is the sensor's one allowlisted bypass).
- A viewer's synced copy refreshes only while VideoScan runs there (CatalogSync's in-app pull, 90 s); the M4 test host is headless, so its nightly Hallie lane reads whatever snapshot the last app session left (11/04: v14 against a v15 build). Idea: a headless pull (`--sync-from-master`) before the nightly's Hallie lane.
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
- Change-driven staleness for the Files line: a drive mount, or FSEvents under catalogued roots since the last check's event id, marks that drive or folder stale and the worker re-checks only it (Rick 2026-11-07, step 2 of the daily file check; not built).
- Validate Catalog… tier 5 should run the full `PRAGMA integrity_check` (today only `quick_check` at open); report it as its own stamp; nightly too (Rick's SQLite operations matrix, 2026-11-01).

## Provenance (top of mind)
- Carrier / capture tables migration — `capture_setups`, `carriers`, `capture_events`, `carrier_spans`, `file_provenance` — its own additive migration and Rick's approval (`provenance_assertions` shipped in v14: Done).
- Phase 1: Triage ▸ "Needs provenance" filter + Provenance sheet grouped by proposed tape; Confirm tape confirms every field; July VHS backfill from folder + encoder + birth date (the 720×480 rule matches zero July files).
- Phase 2: Promote gate hard on role + carrier-or-born-digital, "archive with provenance unknown" override with reason; nudges for setup/videographer/condition.
- Phase 2: regenerate `00_Index/Provenance.csv`, `Carriers.csv`, `Provenance_README.txt` under the index lock; ledger kinds `carrierInspected / captured / provenanceConfirmed / transferSuperseded` appended.
- Carrier inspection step, once per cassette (60 s), before capture.
- Phase 3: "New captures" nudge; H.264 viewing proxy made at ingest so FFV1 masters skim and seek in-app.
- dvrescue per-frame recording dates for the 30 DV masters (biggest free dating win).
- DV rdt as a deterministic date bound: Phase D of provenance_retroactive_2026_10_26.md (reader → `inferred_dates` source `dv-datecode`); needs a ruling on how it ranks against the embedded date.
- (ruling) The four open questions: Provenance.csv vs manifest v4 (deep dive says CSV); role vocabulary (ours vs PBCore generations); hard vs soft gate the first month; the July device-chain line.
- (ruling) Re-digitize the kept tapes natively (10-bit 4:2:2) as a second capture event; does a confirmed better re-capture supersede the July FFV1 masters?
- Later: PBCore XML export; QCTools/MediaConch post-capture QC.
- (idea, Rick 2026-10-25) Catalog right-click **Provenance ▸** {Find Master, Find Similar Footage, Find Duplicates, Find Best/Repaired Version} — ONE door to engines that exist (lineage/archive copies, footage likeness, duplicate groups, Events pick-the-master); phased; a per-file provenance score (option 3: grade and work up the chain, never a catalog restart) comes after the four 10/22 answers. → **Provenance Grade** (auto-generated, per file, evidence-only): #396 (Rick 2026-10-29).
- `provenance_assertions.by = 'rick'` is really "the admin user" (Rick, 2026-11-01, on approving v14): one day replace the literal with the owner's identity (a `users`/owner row or a constant the app sets), by an additive migration that keeps old rows readable; nothing until a second user exists.

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
- (idea, Rick 2026-11-06) **Layer 3's north star: the Rick & Donna Breen family's story, told by evidence.** Repeated analysis builds facts of the shape who · what · when · where, each with its sources (frames, transcript lines, dates, Rick's confirmations), so plain questions work: "when did Timmy graduate high school", "did he ever play guitar", "find Dad telling a story", "how many years did we film down the Cape", "what trips did we take". Not narrative prose; queryable, evidence-first, every answer shows its evidence and its confidence. Local models only (living family, rule 13). Prerequisites, in order: layer 3's §5 fixes (devices, spans, families), confirmed people on footage, events with dates, speaker identity.
- (ruling) Event categories beyond the nine; dismiss semantics; Open = QuickTime or in-app seek.
- (ruling) Cloud use on derived text (captions/transcripts) for later labelling, or local only.
- Bounded retrieval experiment: rules vs SigLIP 2 vs Qwen3-VL-Embedding-2B on held-out occasions, split by occasion and lineage.
- Video LLM follow-ups (2026-10-30): one engine, two samplers (stills for OCR, windows for era/room); era claim under the codec/carrier floor; re-pick the prompt on held-out clips; roomFeatures retrieval once Rick labels 50 places. (A2 is Done.) Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Video LLM, after A0/A1".
- Video LLM: frozen local VLM + structured scene JSON → assertions (era claim, place_signature); era benchmark and 18-event retrieval test first, LoRA only on extraction errors. `docs/design/machine_intelligence.md` (design), `docs/archive/research/video_llm_for_family_media_2026-10-29.md` (research).
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
- **Catalog ▸ Catalog Info** (Rick, 2026-11-01; being built, STATUS): one read-only sheet of a dozen lines read at open time (path, size, schema version, generation, counts, last commit and backup, role, journal, last Verify). Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Catalog ▸ Catalog Info".
- Proposed rename (Rick to rule): Catalog ▸ "Update Catalog…" → "Relink Moved Files…" — the verb rescans and relinks after files moved outside the app; "Update" reads as a schema migration, which is automatic at open and never a menu verb (2026-11-01).

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
- Family Tree AI helper ("Show me some memories…" sparkle, `FamilyTreeMemoriesButton`) has "a lot of potential" (Rick 2026-10-30): the tree's face for the background media expert — a `FamilyMemoryProvider` over the expert's confirmed findings; ties to Story of the Day (#236) and Life & Times (#238). FT-view assistance items proposed in the Charter §3 Claude Feedback (computed documentation grade, refresh discrepancies as review rows, tree facts constraining media dates, cited Record Finder).
- (idea, Rick 2026-11-05) **Living family in the Family Tree view:** Rick's sons (Dan, Mark, Matt, Timmy) and his brothers and sisters are not in the GEDCOM and stay out of FamilySearch (privacy; spouses later). A local-only store of living family, never exported, never sent to a cloud model (rule 13), merged into the tree view behind a "show children / show siblings" chevron or right-click. Needs a schema addition (Rick approves).
- A7 Household Roster, next rungs (measured 2026-10-30, `docs/reviews/household_roster_feasibility.md`): co-presence as a constraint, an identity-bearing attribute, and the People-tab data gaps. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"A7 measured 2026-10-30".
- `A7 Household Roster` (Charter §4 Claude Feedback, 2026-10-30): people as a constraint solver — date window × tree (who was alive, ages, sex, household, likely camera operator) × VLM attribute perceptions (adult/child, age band, sex, infant present) → one or two named candidates with a written reason, proposed to Rick, never written by the machine; no percentage until calibrated. Add to the video-LLM ladder after A5.
- **Public view / web interface** (Rick 2026-10-30, Charter §5; target Jan 2027): a Public tab of media Rick marks "Publish", the tree in full, Hallie for guests; folds #244 and #42. Added 2026-11-09, two right-click verbs on an archived video: (1) **Make Public**, meaning the whole family may watch it — one bit, private by default (DECISIONS 2026-11-09). BUILT 2026-11-09: the bit, the Archive row menu items, the globe; NOT built: the public/private changes as lines in the file's journey (Rick 11/09; the history is in `public_marks`, the journey builder is synchronous over records and does not read it yet), a one-action "make everything private" (wanted only once something is served), a Public filter in the Archive tab, and anything that serves the bit (the web view must be deny-by-default on it); (2) **Show in Photos** (Mac only): link the compact access copy (#280) into a separate archive Photos library, never the master (a 65 GB master never enters Photos). It is a referenced import through AppleScript, since PhotoKit always copies; one album per decade. Goal: watch on the living-room TV through Apple TV. Check first that Apple TV can play a Mac's referenced Photos videos (Media Sharing); the fallback is the TV app on Home Sharing, or AirPlay. Photos reads the date embedded in the file, so the access copy carries the archive date. The family-viewer ruling comes first; design when Rick says so. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Public view / web interface".
- Hallie: agent lane + E1 harness (cloud model in a bounded tool loop, Swift verifier, data-class gate); compound/filter/count queries (QueryAST v3); family web access read-only (#244) and iPad browse (#42) gated on the family-viewer ruling.
- Family Tree crawling (Rick, 2026-10-31): a model-driven job that gathers public records for people in the tree; could live in the background
  service; needs a privacy ruling (what leaves the machine) before any design.
- Hallie: "from the 90s" should count machine eras — add a `machineEra(lo, hi, by)` evidence basis on the presence snapshot, cited as "the 8B's era guess, unconfirmed", never as a date (step 1 UI worker's note, 2026-11-01).

## Storage, dates, improve
- Volumes come and go (#169): auto-resume on remount, wake-on-LAN / SMB auto-mount; #164 cancel mid-walk must not save a partial checkpoint as complete; fold the ⌘⇧V Volumes window into Storage; #189 UUID reads on main beachball on a hung share.
- Dates: #118 plausibility gate (demote transfer dates on digitized tapes); #209 donor edit re-dates shared copies without relaunch; undo sidecar for the retriangulation pass.
- Improve (Nov–Dec): QTGMC/VapourSynth restoration, local upscale/interpolation (#299); Trim (#154); A/V sync check on improved versions (#309).

## Process and tooling
- Mutation testing, incremental (Rick 11/08): start with a LIVE walkthrough Rick can follow (one existing, appropriately small test; show it green, mutate the code under test — flip a `<`, drop a line, return early — rerun, watch it go red or survive); then mutation passes on data-risk modules (Archive, delete/prune) as an overnight theme. A surviving mutant = a test that doesn't check what we think. Not a lane until it proves its worth.
- Validate the gauntlet manifest (`swift scripts/gauntlet/inventory.swift --validate`) in the sensor lane or the pre-push hook: a stale manifest reached main three times (11/06, 11/08, 11/10) and turns the M4 gauntlet RED for bookkeeping, not for a failing test (the pre-commit `manifest_drift.py` sees only newly ADDED test files, not a changed test list).
- UPS wattage menu-bar app (Rick 2026-10-27, just for fun): live watts from the CyberPower UPS over HID, logged to SQLite for weekly/monthly kWh. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"UPS wattage menu-bar app".
- Ultra move follow-ups (2026-10-27): `migrate_data.sh` skips app preferences (Storage list, dup-keep precedence, scan options lived only there); `install.sh` prints "ready" after a stopped preflight; `TimingBudget` treats all 30 Ultra cores as equal (10 Super + 20 Performance) so a busy run reads as quiet → strict false reds; TreeWalkScale wall-clock flake (work 1.0 s, wall 24.6 s at load 42/16); M4's nightly role as headless test host; code defaults `defaultMasterHostname` → RicksUltra.local once declared.
- Swift 6 test-host crash follow-ups (2026-10-25, fix 2ab067d62): confirm `MasterArchivePromoteTests.swift:350` (`var poisoned` mutated in a `progress:` closure) is called on the test's own thread; `nonisolated(unsafe) var` on a CAPTURED LOCAL does not silence the runtime isolation check (BoundaryAuthorization crashed with it); `-test-iterations N` does not repeat Swift Testing tests on this Xcode — repeat runs need N separate invocations.
- Test fixtures that pin `isReachable = true` on unmounted `/Volumes/...` targets (seven files besides DuplicateCodexReviewTests, `grep "isReachable = true" VideoScanTests`): the model's reachability refresh overwrites the pin at the next suspension point (the 2026-10-25 DuplicateReelectionStampTests flake). Any of them that awaits while comparing reachability-derived state has the same latent flake — fix the same way (let the target derive its own facts, or pin through `VolumeReachability`).
- GH issue triage close script (31 done + 16 obsolete + 1 dup; 47 → 23 umbrellas) awaiting Rick's OK.
- Post-cutover stability baseline (the 10/14 one predates SQLite).
- End-of-October Codex spend review; spend the remaining cloud credit before 2026-11-05.
- Log retention prune job (#199); metrics page down to a few vital signs (#310).
- Adversarial 10/18 findings #4–#7 (deferred to the Import removal): close with pinning tests or decline with reasons.
- Fleet roles on the Ultra: a resource plan (cores/RAM per job, weekly calendar), not just a role list.
- Background helper's badged icon (Rick 2026-10-28; `background_service.md` §18 ruling 2): the own bundle `VideoScan Background.app` exists since step 0; the icon badge (gear-in-arrows or checklist-with-clock) is still to draw. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Background helper looks like the app".
- Quit stalls on a sleeping drive (2026-10-28, 24 s): RAMDisk.cleanupStaleMounts lists /Volumes, which touches every mount root; a spun-down drive (LaCieWorkspace) blocked quit 18:36:22→46. Use getmntinfo(MNT_NOWAIT) (in-memory mount table) and give `hdiutil detach` a deadline; test that the sweep never touches a mounted volume.
- SSH builds on the M4 cannot use the "VideoScan Local" key (login keychain locked over ssh → errSecInternalComponent): run_sensors.sh and other ssh-run builds pass the ad-hoc override the nightly already uses.
- Put the Ultra to work (Rick 2026-10-28): bigger Hallie brains A/B, a primed long-context prefix, a LoRA for skill not facts, GPU/ANE batch work, Gemini's engine list, the `.1999_maybe` stem. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Put the Ultra to work".
- Local review models on the night shift (DECISIONS 2026-10-30): run Codex's attended pilot once in a Terminal, then grade candidates against historical bugs before trusting one. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Local review models on the night shift".

- Helper target project hygiene (2026-10-30): Xcode moved the helper's loose `Assets.xcassets` file reference into a "Recovered References" group on first build and re-sorted the pbxproj (committed as Xcode wrote it so builds stop dirtying the checkout). Proper fix: give `VideoScan Background` its own asset catalog with the badged icon (ruling 2 of the service design) or reference the app's catalog from inside its synchronized folder; also the launchd plist shows twice in the navigator (loose ref beside the synchronized folder).
- Unify `JobResourceProfile` (Background job payload: peakMemoryBytes, needsResidentModel, secondsPerUnitEstimate) and `ModelLab.ResourceProfile` (peakRAMGB, needsResidentModel, s/window per host, weightsLocation) into one Core type — same concept, two shapes born on parallel branches 2026-10-30; the service checks the one the job declares.
- Metrics board: a coupling figure beside CCN per module (count of `extension VideoScanModel` files, imports per file, fan-in/out) so the library extraction the background service forces shows in the number it moves (Rick 2026-10-30, `background_service_2026_10_30.md` §0.5).
- Metrics board: a per-file "Swift 6 warnings" column straight from `scripts/warnings_baseline.tsv`, and watch CCN / grades across the migration (Rick 10/25; stage 2 of `docs/archive/design/swift6_migration_2026_10_25.md`).

- **Nightly UI smoke on the M4 (ruled 2026-10-28):** fix the 5 stale UI tests (#408), add quit-and-relaunch, keep the M4 unlocked overnight (Rick), a launchd UI lane before 02:00, a morning line for both Studios. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Nightly UI smoke on the M4".
- **Ultra nightly fires at 05:00, not 02:00 (10/28 and 10/29):** the plist says Hour 2 (installed 10/27 20:24), the job is loaded and enabled, the Mac was awake, nothing else calls the guard. 05:00 EDT is exactly 02:00 Pacific; the Ultra was set up 10/27 and launchd has not restarted since (uptime ~1.5 days). Check after the next reboot; if it persists, `launchctl bootout`/`bootstrap` the job and compare.
- **Real-volume sensors lane (2026-10-29):** `RealVolumeWalkSensorTests` (LaCie incident directory) now runs only with `VIDEOSCAN_REAL_VOLUME_SENSORS=1`, after it hung the Ultra's 10/29 nightly for 95 min (cause unproven; guess: a removable-volume privacy prompt to a fresh test host). Give such sensors an attended or pre-granted lane (and a time limit) so they still run somewhere.
- **The M4 catalog is schema 12:** its nightly Hallie replay is "incomplete" (0/56, 0/817) because this build opens a catalog read-only only at schema 13. Refresh the M4 copy, or point the M4 replay at the Ultra over the tunnel.
- **UI tests, next increment (Rick 2026-10-29):** sign the Ultra's UI test builds with "VideoScan Local" so one drive-access Allow sticks (flow 7 and `scripts/m4_run.sh` are built; its verdict JSON and `refs/m4run/green` are still to do). Detail: `docs/archive/backlog_detail_2026_11_01.md` §"UI tests, next increments".
- **Hallie model host is per-run:** the harness on the Ultra can use the M4's model over an ssh tunnel (`--host`), so model A/B runs need no catalog copy on the M4.

- **Hallie benchmark 2026-10-28 follow-ups** (seven): automatic harvest from both Macs, per-turn latency in ms, align Ollama versions, MLX numerics by chip, a stale CyberBrain id for Dad Breen (Rick's data call), an alias guard in `resolveDetailed`, strict-042/045 placement (Rick to rule). Detail: `docs/archive/backlog_detail_2026_11_01.md` §"Hallie benchmark 2026-10-28 follow-ups".
- M4 real-media testbed (Rick 2026-10-28): a marked, expendable SSD of real media the tests may write to, the M4 as a read-only viewer of the Ultra's archive, and overnight menu-driving UI runs against it. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"M4 real-media testbed".
- M4 catalog fault-injection testbed (Rick 10/26): a nightly `.backup` copy on the M4 that a fault suite attacks at production scale, every case refused in words or recovered. Detail: `docs/archive/backlog_detail_2026_11_01.md` §"M4 catalog fault-injection testbed".
- Overnight code review with local big models (Rick, 2026-10-31; Codex's `attended_review.py` pilot is the seed): rules such as "review the
  module with the worst CCN grade" and "review the week's changes with their test coverage"; graded against held answers before trusting.

## Docs still to write (when their subject is live)
Catalog schema and commit model for readers (replaces `database_design.md`; carry its POI layout, bundle contents and recovery runbook) · MFO job lifecycle and how to add a job · the removal lanes today and the one-engine target · Archive Angel: what stays (after Q8) · Family Tree read model (after Q3) · splitting `VideoScanModel` (after Q11) · family viewer mode · P0 retrospective: how integrity fell off the table · final provenance design after Rick's four rulings · post-cutover stability baseline · segments decision record.
- The cloud briefs (`docs/briefs/cloud/`) retire to the archive after 2026-11-05. (The rest of the 10/31 "docs for Rick to rule" line is Done.)

## Machine intelligence and the background service (grouped 2026-11-01)
- Analyzer order (Rick, 2026-10-31): oldest first — 1960–2010 is the valuable span; one video of the grandmother outweighs a thousand of the
  granddaughter; phone footage last (its metadata dates it). People-tab facts (birthdays, sex, descriptions) as constraints: constraint
  propagation from a birthdate to a date window; Household Roster as the filter.
- MFO verb repeats (Rick, 2026-10-31): Rick has seen verbs redo work on unchanged files; audit each verb's skip rule against the digest-keyed
  observation rule (`background_service.md` §11) and name the offender.
- Rick's architecture note (`video_intelligence_architecture.pdf`, read 2026-10-31): adopt keyframes by scene-change detection for the
  sampler, perceptual video hash and SigLIP embeddings as dedup tiers 2–3, constraint propagation from birthdates; events stay rulings
  (not DBSCAN); cloud offload stays a §9 ruling and never carries family pixels (rule 13).
- Analyze tab: a row/button to start the era job (today: `--enqueue era` / `--run era` from the helper binary only).
- A stable home for the installed app and its helper (Rick 2026-11-09: "keep the BG process executable somewhere so I don't keep accidentally cleaning & rebuilding it"): today launchd resolves `VideoScan Background` inside whichever build product holds bundle id `Rick-Breen.VideoScan`, so Clean Build Folder pulls the running helper's binary out from under it (seen 11/09: it ran from `CleanBuildFolderInProgress`). Proposal: an install step that copies a Release build to `/Applications/VideoScan.app`, and only that copy registers the helper; dev builds talk to it and never re-register. Needs Rick's ruling on the install workflow.
- Content Analysis ▸ a read-only **results sheet** for the helper's work (Rick 2026-11-04, "how can we see what it produced?"): counts by outcome (era found · no usable era · given up after 3 tries, with the reason · still to do), a clickable file list per outcome, and the "agrees with your confirmed date within 5 y" number — today the only per-file view is the inspector's Machine era line, and era.none / give-ups show nowhere.

## To file as issues (found 2026-10-31 → 2026-11-01)
- Found while mapping files (2026-10-31 night, docs workers): `previewSweepEnabled` sits in the prefs plist but no code reads it (stale key);
  `Media/MediaPersonLinks.swift` has no caller outside its own file (dead?); `CatalogSync.defaultMasterHostname` is still `RicksM4.local`
  while the live catalog is on the Ultra (ruling); `findtag-journal/` (572 MB, 425 entries) has no bound in `FindTagJournal.swift`;
  `tests/test_docs_links.py` counts the git-ignored `retired-2026-10-reset.zip` (in the archive folder) as a miss in any fresh worktree (allowlist it);
  the gauntlet runner leaves ~6 GB of DerivedData per run under `~/Library/Logs/VideoScan/gauntlet*/` (strip build dirs, keep xcresults).
- To file (dv_datecode run 2026-11-01): 25 MXF rows the catalog labels "DV 25" are MPEG-2 by their own bytes (a codec label from the MXF descriptor, not from the stream — rule 1: a shown fact comes from evidence); 190 "DV" mov/mxf rows hold no picture frames at all (QuickTime reference movies, essence-less MXF) — check whether their media is already in the corpus under another row, then decide what the catalog should say about a reference movie.
- To file (date-review build 2026-11-01): the preview cache holds no poster or filmstrip for any of the 297 DV digests — the preview sweep skips raw DV (or never reached it); every DV row in the Catalog shows no picture until it does.
- To file (11/01): a `.vs.archive.mov` the app itself transcoded has no `lineage` row to its source `.dv` (GrampaBreen tape: the archive copy and the raw DV are two contents with nothing linking them), so a date Rick sets on one does not reach the other and nothing can propagate it; check how many archive transcodes lack a lineage row and whether the Promote path writes one.

## Done (moved here 2026-11-01; kept for the record)
- Background step 1 candidate (2026-10-31): the 8B era/OCR expert as the helper's first real job — A2's windows + contracts over the whole catalog, assertions into model-lab.sqlite with model + prompt hashes, sidecars + journal to the app's committer; needs §7 ruling 4 (step order).
- Schema v14 `provenance_assertions` with the rejected-value veto trigger — shipped 2026-11-01 with background step 1 (DECISIONS 2026-11-01); was the last item of BACKLOG's "Phase 1: schema v13 additive" line.
- Video LLM A2 (2026-10-31): the 8B halves the era error and lifts OCR to 95 %; seated for era/OCR, the 32B parked (DECISIONS 2026-10-31; `docs/reviews/video_llm_benchmarks.md`).
- Human-vs-machine date convergence (Rick, 2026-10-31; ruled "go"): (1) Catalog filter chip "Confirmed date" — in progress (`feat/confirmed-date-filter`); (2) inspector date block gets one line "Machine era: 1991–1995 (8B, <date>)" under "Confirmed" — lands with background step 1 (the 8B era job writes assertions first); (3) Catalog Status line "Machine era agrees with your confirmed date within 5 y: N of 73 (p %)" — the convergence number, read week over week; a dashboard sparkline later at most. Not building: a machine-date filter, a comparison table, a side-by-side mode. **Built:** (1) the Confirmed Date filter (10/31), (2) the inspector Machine era line and (3) the Catalog Status convergence line (background step 1, 11/01).
- Docs for Rick to rule after the 10/31 consolidation — done in the 2026-11-01 consolidation (`docs/archive/README.md`): Codex transcripts folded into `docs/reviews/codex.md`; `m4_staging_gate`, `nightly_adversarial_review_design`, the two provenance research docs, `cyberbrain_design`, `kinship_inference_design` and `October_Design_Retrospective` archived. Original line: Docs still for Rick to rule after the 10/31 consolidation (`docs/design/machine_intelligence.md` report): fold `docs/reviews/codex/` per area once #404's headers are fixed; archive `m4_staging_gate` and `nightly_adversarial_review_design` once the scripts' comments point elsewhere; the cloud briefs retire after 2026-11-05; the two provenance research docs archive when v14 lands; `cyberbrain_design` / `kinship_inference_design` headers say PROPOSED for things that appear built; `October_Design_Retrospective` keep or fold.
- If the regrouped Catalog menu still confuses after a few days of use, "Content Analyzer" becomes its own top-level menu holding the analyzers, the background service status and the Content line of Catalog Status (Rick, 2026-11-01, "let us see for now").
- Viewer Macs (Rick ran the app on the M4 over the Thunderbolt bridge, 2026-11-01): (1) the Family Tree tab refuses entirely when the designated Master Archive is absent (`FamilyAssetStore.Access.unavailable`, by design for writers); on a viewer it should open the compiled graph read-only and say photos/documents are unavailable until the archive is connected — a data-risk-area change (safety-critical path, Codex) after Rick's ruling; (2) an SMB mount of a known volume carries a different UUID, so the viewer treated the mounted CrucialX10 as a new drive and held 5,642 "new" rows — a remote mount of a known volume should resolve to that volume (share name, then digests), never a second one; (3) a ten-line "run the app on the M4 as a viewer" section in guides/operations.md.
- **Background helper throughput (Rick 2026-11-03):** (a) on the 96 GB Ultra, let model jobs run at a measured reduced rate while Rick is at the keyboard instead of waiting (`background_service.md` §14.5 `.trickle` today = the model never loads); measure UI latency and memory before/after; (b) run VideoScan Background jobs on the M4 over the TB5 bridge (read media over the bridge or the M4's own mounts; observations journal back to the master).
- **Testbed findings from the 2026-11-10 night shift, not fixed (each needs a ruling or a design):**
  - *The M5 Ultra's 02:00 nightly builds and tests `~/dev/VideoScan`* (`REPO="$HOME/dev/VideoScan"` in `nightly_local_tests.sh`): Rick's checkout, pulled at 02:00 when it is on main and clean. STATUS says "never a checkout". A branch or uncommitted work left there is what gets tested (the row says `dirty` / the branch). Give the nightly its own worktree, as the M4 on-demand runs have.
  - *The M4's nightly adversarial review has been off since 11/07*: three nights of `claude exit 1`, then it disabled itself ("run `adversarial_nightly.py enable`"). Most likely the `claude` CLI on the M4 needs a login or a key. Needs Rick at the M4.
  - *Core tests fail in the M4's 04:00 coverage build* (Debug + coverage, beside the 04:30 analysis lane): 27 issues on 11/09, timing budgets (25 M landmarks, busy timeout, 100k journal lines, JobSchedule). The Release nightly passes them. Either the coverage run sets the loose timing mode or the two lanes stop overlapping.
  - *The sensor lane's warning ratchet only sees files compiled in that run*: with a warm DerivedData a file is not recompiled and its warnings are not seen (11/09: two warnings reached main behind a GREEN lane). Force the changed files to recompile, or run the ratchet on a clean build before a merge.
  - *The M4's own catalog is a viewer copy at schema 14, last written 11/02.* Three tests failed on it for that reason (fixed). Is viewer sync to the M4 still running, and should the test host hold a current copy?
  - *A launch refused or failed before any row is published is silent on the page* until the 36-hour STALE cue. A "last attempt" line per Mac would say it sooner.
