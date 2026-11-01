# Retroactive provenance and video fingerprinting — deep dive (2026-10-25, overnight)

Answer to Rick's `provenance_agent_spec.md` and `provenance_architecture_blueprint.pdf` (ideaphoria docs, with Gemini).
Inputs: the codebase inventory (`.scratch/provenance_inventory_2026-10-25.md`, every claim file:line, catalog read
`mode=ro` at generation 1110) and the web research (`.scratch/provenance_web_research_2026-10-25.md`, every claim a URL).
Builds on `docs/design/provenance_lightweight_2026_10_22.md` and `docs/research/provenance_deep_dive_2026-10-23.md`;
repeats neither. Rick's standing answer "Provenance.csv, not manifest v4" is taken as given. This is research, not a
design: nothing here is built until Rick says "design it".

## In one page

1. **The spec's pipeline is two-thirds built already, and the spec did not know.** Tier 1 (perceptual hash) exists as a
   32-frame 64-bit dHash fingerprint with a statistical verdict (`App/Media/PerceptualHash.swift`,
   `PerceptualFingerprinter.swift`, table `perceptual_prints`, MFO job "Fingerprint Pictures…"); a second, pixel-domain
   sliding aligner exists in Python (`scripts/footage_spectrum.py`, "Compare Footage…"). Tier 3's model is bundled:
   Qwen2.5-VL-3B-4bit runs on MLX-Swift (Metal) in `MLXVLMCaptionRunner` and has already captioned 4,518 contents, with
   1,448 OCR date candidates feeding `DateTriangulator`. The **Shazam-style audio landmark matcher** in Core returns
   offset in seconds and `containedInMaster` / `overlap` verdicts and is stamped on **8,434 of 8,634** live video rows.
   Only Tier 2 (CLIP embeddings, vector store) is absent.
2. **What is actually missing is small and specific**: (a) the picture fingerprint samples 32 frames at *normalised*
   positions, so a cut clip cannot slide against its master — it must become a fixed-rate 1 fps *timeline*; (b) there is
   no catalog-wide index for either print (audio and picture match per pair only), so "find this clip's master" cannot
   be asked; (c) there is no typed relation that records "clip X is master Y at 12:40–13:20" with its proof; (d) there
   is no per-field assertion table (`inferred | confirmed | corrected | rejected`) — the 10/23 deep dive's
   `provenance_assertions`.
3. **Order of work, by proof per hour of effort**: audio index first (no new ML, 8,434 rows ready tonight) → picture
   timeline v2 + index + offset vote → the relation table and the Catalog "Provenance ▸ Find Master" door → the free
   deterministic lineages (dvrescue `rdt` for 937 DV rows, encoder-signature chains, iMovie/FCP project files) →
   VLM era prompt **only after a measured benchmark** → MobileCLIP2 event suggestions last, benchmarked against the 18
   events Rick has already confirmed.
4. **Gemini is real and off the table.** Gemini 4 Argon (30 Sep 2026) and Antigravity 2.0 (`agy`, I/O 2026) exist;
   rule 13 forbids sending anything with living immediate family to a cloud model, which is nearly every reel after
   1975. Usable only for deceased-only or non-family clips after a per-clip human gate — a niche, not a tier. The M5
   Ultra is the answer the privacy rule allows.
5. **The spec's SQLite schema is wrong for this repo** and is replaced in §6: UUID keys and `file_path UNIQUE` violate
   "identity is the whole-file SHA-256"; `machine_provenance.user_confirmed` is a bit where the rulings want a state per
   field with a rejected-value veto; fingerprints belong in a sidecar DB, not the catalog (10/14 ruling); `ON DELETE
   CASCADE` violates "rows are never deleted".
6. **Era dating by a VLM is unproven**: the best published still-photo result is a mean error of ≈ 7 years; no paper
   estimates the decade of home video. A VLM year range earns a ±7-year bar and the lowest rank among date sources,
   below folder year — and only after it is measured on the 5,635 live videos that already carry `creation_time`.

## 1. The spec's items, one verdict each

| Spec item | Status in the repo today | Verdict |
|---|---|---|
| Tier 1: pHash timeline, Hamming sliding window | dHash 64-bit, 32 frames, normalised positions, ±2-index alignment, verdict + coincidence bound (`PerceptualHash.swift:26-56`); 4 rows computed, job never run | **Exists, wrong sampling.** Upgrade to a 1 fps timeline (§3) |
| "Custom Metal DCT" | — | **Over-engineered.** A 32×32 DCT is microseconds on Accelerate `vDSP`; decode is the cost (VideoToolbox for HEVC/H.264/ProRes; DV, MJPEG and FFV1 are software) |
| "Thread-safe frame worker pool saturating the GPU" | one-ffmpeg-pass per file, one lane per volume in every backfill job (`PerceptualFingerprintBackfillJob.swift`) | **Keep the lane model.** Lanes are per volume because drives, not cores, are the limit on this archive (7.55 TB on spinning LaCie/SanDisk) |
| Tier 2: MobileCLIP / EVA-CLIP on ANE, DBSCAN into "Event Crates" | no embedding model, no vector store; Events v1 clusters by folder/date adjacency + caption/transcript rules (`EventsPlan.swift:12-42`) | **Not built; suggestion-only when it is.** No published evaluation shows CLIP clustering finds home-video *events*; it finds near-duplicates (Immich threshold 0.02–0.03). Ruling 2026-09-23 stands: similarity never creates lineage or moves a date |
| Tier 3: Qwen2-VL / LLaVA-Video via mlx-vlm | Qwen2.5-VL-3B-4bit on MLX-Swift, 3 prompts per frame (date / scene / text), 448×448, one frame at a time (`CaptionRunner.swift:8-26, 437-546`) | **Exists.** Qwen3-VL (Oct 2025, Apache-2.0, native video with timestamps) supersedes; mlx-vlm's MoE video path was broken ~Sep 2026 — pin versions, keep a regression clip set |
| "VLM infers capture medium, clothing era, ages → year range 0.88" | `DateTriangulator` already fuses OCR burn-in, camera stamp, spoken/caption years, age + birth year, folder year, export ceiling, media-era floors into a dated claim with a written reason (`DateTriangulator.swift:21-106`) | **Partly.** Add an *era* claim kind at low confidence after a benchmark (§5). Confidence words come from evaluated rules, never the model's self-assessment (events_design.md:25) |
| Gemini 4 Argon + Antigravity 2.0 + "customtools mode" | — | **Real, real, not a name.** Barred by rule 13 for family footage |
| "Multi-million token context, feed full-res video" | — | **Partly:** 1M tokens; ~3 h at low res per request; 20 GB per file |
| Schema `media_assets / asset_fingerprints / machine_provenance` | `content(digest PK)` IS the asset table; `sound_prints` and `perceptual_prints` ARE per-engine fingerprint stamps; `people_tags.kind`, `footage_decisions`, `event_decisions`, `inferred_dates` are the existing machine-vs-human patterns | **Replace** with §6 |
| "Memory-generous RAM caching" | backfills budget memory explicitly (audio ≈ 115 MB per hour of audio, ≤ 1.5 GB in flight) | **Fine as a principle**; the bottleneck is decode and drive throughput |
| "No lazy approximations, no TODO placeholders" | CLAUDE.md rules 7–9 | Already the rule |

## 2. What the archive looks like to a fingerprint engine (numbers, 2026-10-25)

| Measure | Value | Why it matters |
|---|---|---|
| Live video rows / distinct digests | 8,634 / 4,999 | copies are already known by hash: 4,662 digests have > 1 live file |
| Hours / bytes | 450.7 h / 7.55 TB | 1 fps × 450 h ≈ 1.6 M frames; at 32 B per 256-bit hash ≈ **52 MB** for the whole archive |
| Audio prints | 8,434 of 8,634 rows stamped (5,374 fingerprinted, 1,014 no audio, 480 with 0 landmarks) | audio alignment is ready now; **no index** exists |
| Picture prints | 4 rows | the picture job has never been run |
| In a footage group | 3,753 rows (identical 1,735 · likely 1,127 · possible 121) — metadata only, no pixels | the groups are the *candidates* a fingerprint pass should confirm or split |
| Duplicate groups with > 1 live member | 1 | copy detection is finished work; the problem left is *content* lineage, not byte copies |
| Lineage recorded | `lineage` 18 rows (16 "unrecorded"), `lineage_pending` 70, `supersessions` 0 | retroactive lineage is essentially empty |
| Rows with no date evidence of any kind | 2,687 | the population an era estimate would serve |
| Codec families | HEVC/MOV 4,042 (iPhone) · H.264 1,153 · DNxHD/MXF 993 · **DV 937 (+322 DV-25 MXF)** · MJPEG 632 · ProRes 211 · **FFV1/MKV 75 = 2.4 TB, 67.8 h (the VHS masters)** · 113 undecodable MXF RGBA | DV rows carry per-frame recording dates nobody reads; the FFV1 masters are the slow decode |
| Durations | 7,000 of 8,634 under one minute; 172 over an hour hold 263 of 451 h | the "clip → master" question is mostly "short iPhone/DV clip → hour-long tape capture" |
| `probe_extra.tapeName` present | 0 rows | the Avid tape-name hint in the 10/22 draft has no data behind it |
| Confirmed events | 18 (42 members) | a ready-made ground-truth set for any event-clustering claim |

## 3. Tier 1, redesigned on what exists: deterministic alignment

**3.1 Audio first (no new ML, one night).** `AudioFingerprintMatcher` already votes `tMaster − tQuery` per landmark, takes
the best ±1-frame window, and reports offset in seconds, coverage, longest run and the matched span inside the master
(`AudioFingerprintMatcher.swift:208-294`). What is missing is a **catalog-wide inverted index** (hash → (digest, frame))
built once from the sidecar's 209 MB of blobs — the per-pair `AudioFingerprintIndex` generalised to N masters — and a
query "which digests contain me?" that returns ranked `containedInMaster(offset)` verdicts. This answers "Find Master"
for every sounded clip in the archive today. Cost: the index is ~8 B per landmark; a 16-minute tape is ~150 KB, so the
whole archive is a few hundred MB in memory, built in seconds. Silence is evidence for nothing (10/14 ruling) — silent
clips fall through to 3.2.

**3.2 Picture timeline v2.** Keep `PerceptualFingerprinter`'s one-ffmpeg-pass shape and change the sampling and the hash:

| Today (v1) | v2 |
|---|---|
| 32 frames at normalised positions in the middle 90 % | **1 frame per second** from 0 to end (a clip then slides against its master by construction) |
| 9×8 dHash, 64 bits | **PDQ-class DCT hash, 256 bits, with a 0–100 quality score** (same family, more bits, a built-in "this frame is black / flat / a fade" filter; re-encode/resize robustness 99.96 % measured) |
| no crop handling ("letterbox defeats it", `PerceptualHash.swift:50-56`) | **black-bar detection first** (ffmpeg `cropdetect` logic) and hash the active picture; exclude the bottom 10 % where camcorder date stamps and deck OSDs sit (or hash both) |
| interlace ignored | hash one field (or deinterlace) — the comb pattern moves the DCT |
| compare at index offsets 0, ±1, ±2 | **offset vote** (Hough over `t_master − t_query` in 1 s bins, slope 1.0; retry 25/30, 30/25, 0.8, 1.2 only when the peak is weak) — the same algorithm the audio matcher runs; upgrade to a temporal network only when a real multi-segment case appears (VCSL: TN 86 % F-score vs Hough 77 %) |
| `perceptual_prints.hashes_b64` in the catalog | **sidecar `picture-prints.sqlite`** keyed `(content_digest, size_bytes, engine_version)` exactly like `audio-fingerprints.sqlite` (10/14 ruling: bulk in a sidecar, the catalog carries the stamp); `perceptual_prints.algorithm_version` → 2 |

Known failure modes to design around, with tests: static scenes and slow pans (runs of near-identical hashes — vote on
runs, not single frames); fades/black/white (quality ≤ 49 discarded); 4:3↔16:9 stretch and crops > 5 % (PDQ's known
weakness — the crop normalisation above, and §4's learned descriptor for the residue); camcorder stamps (tolerated,
widen thresholds or exclude the strip). Static-scene false positives are the one that bites a family archive: two
different Christmas mornings in the same living room — the *audio* vote disambiguates when sound exists, and the
coincidence bound already in `PerceptualHash.swift:131-160` must stay in v2.

**3.3 Throughput.** Decode dominates; hashing is noise. Rough budget on the M4 Max, one lane per drive: HEVC/H.264/ProRes
through VideoToolbox at 1 fps output run far faster than real time; DV/MJPEG/FFV1 are software decodes. The 67.8 h of
FFV1 masters at 1280×720 are the slow set — expect an overnight for that drive alone; measure on three files before
promising a number. Storage is trivial (≈ 52 MB for the archive).

**3.4 Direction is never inferred.** Audio or picture containment proves *same content* and the *offset*; it does not
say which is the master (ruling 2026-09-23: containment gives no direction). The draft "which is better" comes from
Compare Media's existing rule (longer audible › original-generation codec › frame size › bit rate,
`EventRecommendation.swift:5-18`) and `FootageOriginality`; Rick confirms.

## 4. Tier 2 — embeddings, honestly

- **Copy residue (crops, collages, overlays), later:** SSCD/DINO-class per-frame descriptors are where learned models beat
  hashes (VSC23: 60.5 % → 87.2 % μAP). Rare in a family archive (iMovie exports with titles, DVD menus). Build only when
  3.2 leaves a measurable residue. DINOv2 is Apache-2.0; DINOv3 has a custom licence; SSCD weights are CC-BY-NC.
- **Events ("same room / same occasion"):** MobileCLIP2-S2 (512-d, Core ML on the ANE, ~ms per frame) is the right
  embedding if we do it; mean-pool one frame per 10 s per scene; store in a sidecar; compare only within one model
  revision (events_design.md:127). It may only *suggest* in the Related ladder's rung 3 with the distance shown.
  **Gate:** measure on the 18 confirmed events (42 members) before anything is shown to Rick — precision at k against
  his own confirmations is the only evidence that would justify it. No published home-video evaluation exists.

## 5. Tier 3 — the local VLM, measured before trusted

- The model is already here (`mlx-community/Qwen2.5-VL-3B-Instruct-4bit`, MLX-Swift, one frame at a time). On the
  M5 Ultra the candidates are Qwen3-VL-32B-Instruct 4-bit (~20 GB) or Gemma 4 31B (65–75 GB peak at long context) —
  one resident model beside the app. Whether `mlx-swift-examples`' `MLXVLM` supports Qwen3-VL video input is **not
  verified**; the Python `mlx-vlm` path does for dense models. Flag before any plan.
- **Era prompt** ("clothing, cars, TV sets, picture quality → year range + rationale") becomes a new
  `DateCriterionClaim.Kind` at confidence ≤ 0.3 with a ±7-year range, ranked **below folder year**. It never dates an
  archived row (ruling 2026-07-05/10-14) and never overrides a human.
- **Benchmark first (the red/green for a model):** 200 clips with a trusted date (from the 73 user dates and a stratified
  sample of the 5,635 `creation_time` rows: iPhone era, DV 1995–2005, VHS 1984–95 transfers) → run the era prompt → report
  MAE and the fraction within ±5 years, per decade. Ship the claim kind only if MAE < 7 years on the VHS/DV strata
  (the literature's still-photo ceiling); otherwise the prompt stays a research note. The three existing prompts
  (date / scene / text) are *not* re-run.
- Every assertion a VLM makes is `inferred` with evidence = the rationale text, the model id and revision, the frame
  times — and a rejected value is never re-proposed (the trigger of §6).

## 6. Records: what the spec's schema becomes here (v13, additive, raw SQL, Rick approves)

| Spec table | Here | Why |
|---|---|---|
| `media_assets (id UUID PK, file_path UNIQUE, file_hash)` | **`content(digest PK)` + `files(content_digest FK)` — exists** | identity is the whole-file SHA-256 (rule 6); a path is a location, several per content |
| `asset_fingerprints (asset_id, timestamp, perceptual_hash BLOB)` | **sidecar `picture-prints.sqlite`**: `prints(content_digest, size_bytes, engine_version, recipe_id, fps, frame_count, quality_floor, blob)`, blob = packed (second, hash256, quality); catalog stamp `perceptual_prints` (exists; `algorithm_version` 2) | 10/14 ruling; the audio sidecar is the template; one row per digest per engine, never per file |
| `machine_provenance (asset_id PK, derived_from_master_id, confidence, year range, method, log, user_confirmed 0/1)` | **`provenance_assertions`** (10/23 deep dive): `(subject_kind, subject_id, field, value, state inferred\|confirmed\|corrected\|rejected, by, at, confidence, evidence_json)`, `BEFORE INSERT … WHEN state='inferred' AND EXISTS (rejected same subject/field/value) → RAISE(IGNORE)`; display = latest human row else inferred | one bit cannot hold *who said so*, the correction, or the veto; People tags already show the bug of not reading rejections (`FamilyTagging.swift:80,102`) |
| `derived_from_master_id` (self-FK) | **`content_excerpts`** (new, append-only): `(child_digest, parent_digest, child_start_s, child_end_s, parent_start_s, parent_end_s, proof audio\|picture\|both, offset_s, coverage, audio_engine, picture_engine, recorded_at)` — machine *evidence* of containment, no direction; plus `carrier_spans` for tape ranges (10/23) and the existing `supersessions` for Rick's confirmed "this transfer replaces that one" | ruling 2026-09-23: typed relationships with ranges, containment gives no direction; supersession must be proven (sound/picture/overlap + stated criterion + confirmed) |
| `ON DELETE CASCADE`, `ON DELETE SET NULL` | none; `BEFORE DELETE … RAISE(ABORT)` triggers on evidence tables, as `footage_likeness` and `ledger` already have | rows are never deleted (rule 2) |
| `generation_method CHECK IN (PHASH_TIMELINE, CLIP_CLUSTER, VLM_REASONING)` | the `by` column of an assertion: `rick <date>` or `machine <engine>:<version> <confidence>` | engines come and go; the evidence string names the exact one |
| `machine_inference_log TEXT` (raw JSON) | `evidence_json` on the assertion + the one log sink (START/OUTCOME lines, rule 5) + ledger kinds `captured`, `provenanceConfirmed`, `transferSuperseded` (10/23) | one log, one ledger |
| `idx_fingerprint_lookup ON (perceptual_hash)` | an in-memory inverted index built from the sidecar at job start (hash → (digest, second)), like `AudioFingerprintIndex`; 256-bit hashes are matched by Hamming ≤ 31, which a B-tree index cannot serve — use multi-index hashing (4 × 64-bit bands) if the linear scan ever matters (1.6 M entries: it will not for years) | the index is a job artefact, not a table |

Travelling copy: `Provenance.csv` and `Carriers.csv` regenerated under the index lock (10/23 §1); an excerpt proven by
machine appears in the CSV only once Rick has confirmed the relationship it supports.

## 7. The free lineages the spec did not list (deterministic, no model)

| Source | Rows it serves | What it proves | Cost |
|---|---|---|---|
| **dvrescue / dvpackager per-frame `rdt`, `rdt_nc`, `tc`, `tc_nc`, `rec_start`** (MediaArea, BSD-3) | 937 DV rows + 322 DV-25 MXF + any DV-in-MOV | the *shoot* date per stretch (camera clock) and the cut list of a tape; abutting/overlapping `rdt` ranges in two files = one carrier; timecode jumps order the captures | one CLI pass per file; the biggest single dating and tape-reassembly win in the archive; **nothing reads `rdt` today** |
| **Encoder-signature chains** | all 8,634 | `Lavf61.7.100` + 1280×720p30 = the July 2026 VHS setup; `Photo-JPEG` 582, `DV/DVCPRO NTSC` 164, `ProRes 422` 118, `Lavf6x` ≈ 276, iMovie/QuickTime/Avid writer tags; ffmpeg `idet` finding interlaced pixels inside a progressive-flagged H.264 = a deinterlace-less re-encode of an analog transfer = later generation | metadata already in `probe_extra`; `idet` is one cheap pass |
| **Edit project files are lineage** | the Projects volume (624 rows) and every `iMovie Events.localized/<Event>/…` tree #383 now skips | FCPXML `asset-clip → asset → media-rep` original paths; iMovie `.rcproject` / `.imovielibrary` bundles; Avid bins/AAF list source tapes; the *event folder name* beside a render cache ties that cache's project to a source clip and a tape | parse, never admit — the skip stays; a reader walks the same folders for lineage only |
| **VHS / camcorder OSD OCR** | the 1,448 `ocrDate` and 2,002 `ocrText` digests already captioned | a burned-in camcorder stamp survives every re-encode (same content across generations); a deck OSD ("12:00AM THU", "SP") marks one transfer session | classify existing captions; no new inference |
| **8 mm / Super 8 cadence** | unknown count — **ask Rick which film scans exist** | a telecine from 18 fps duplicates every 3rd/6th frame; the duplicate-frame period identifies the pulldown, the original speed, and that two scans share a reel | `mpdecimate`-style frame-difference pass; no published tool |
| PRNU sensor fingerprint | iPhone originals only (HEVC re-encodes defeat it) | which of five devices shot a born-digital file — but `origin make/model` already says so for 4,104 rows | **not worth it** here |
| C2PA content credentials | none today (no iPhone writes them; no camera passed the conformance program as of 2026) | read when present at ingest; never build on it | — |

## 8. Hardware (M4 Max now, M5 Ultra 96 GB from 10/28)

- Tier 1 is **drive-bound, then decode-bound**: one lane per volume (the existing backfill shape), VideoToolbox for the
  hardware codecs, ffmpeg threads for DV/MJPEG/FFV1. GPU shaders buy nothing for a 32×32 DCT.
- The ANE serves Core ML (MobileCLIP2, Vision feature prints); MLX serves the VLM on Metal. They do not contend.
- A resident 20–75 GB VLM beside the app is the M5 Ultra's job; the M4 Max keeps the 3B model. One model instance, no
  concurrent inference (`CaptionRunner.swift:21-26` already enforces this).
- "Memory-generous caching": the existing budgets (audio ≈ 115 MB per hour in flight, ≤ 1.5 GB) are the right shape;
  a 1 fps picture timeline is 32 B per second and needs no cache at all.

## 9. Phases, if Rick says "design it" (each with the five test dimensions + truth + Codex where it writes)

| Phase | Builds | Schema | Proof it works (red/green) |
|---|---|---|---|
| **A. Find Master by sound** | catalog-wide audio inverted index (job artefact); `Provenance ▸ Find Master` on the Catalog row menu (Rick's 10/25 idea; one door to existing engines) returning ranked `containedInMaster(offset)` with the matched span; one log line per answer | none | a synthetic corpus: 30 FamilyArchive masters → 100 clips cut at random offsets with ffmpeg, re-encoded at three qualities, some muted → recall/precision/offset error (±1 s) reported as numbers |
| **B. Picture timeline v2** | 1 fps PDQ-class timeline with quality, crop/strip/field normalisation, sidecar store, index, offset vote; "Fingerprint Pictures…" job re-pointed at v2 | `perceptual_prints.algorithm_version` 2; new sidecar | same corpus plus letterboxed, stretched, date-stamped and static-scene variants; the coincidence bound reported; measured decode throughput per codec family |
| **C. Excerpt evidence + Provenance sheet** | `content_excerpts`, `provenance_assertions` + veto trigger (v13 part 1, with `capture_setups`, `carriers`, `capture_events`, `carrier_spans`, `file_provenance` from the 10/23 deep dive); the Provenance sheet shows "contained in <master> at 12:40–13:20 (sound · picture)" as inferred evidence; Rick confirms direction / supersession | v13 additive; Codex pass (writes the archive's index on Promote) | rule-8 writer tests (debounce, write hold, role flip, relaunch); the veto trigger seen to refuse a re-proposal; the 10/23 `Clip 03.dv` worked example as a truth test |
| **D. Free lineages** | dvrescue `rdt` reader → `inferred` date and carrier spans for DV; encoder-chain and `idet` generation evidence; FCPXML / iMovie project reader → `lineage(kind edit)` edges (new CHECK value, additive) | small additive | 30 DV masters: `rdt` dates vs the 18 known capture dates; a synthetic FCPXML with three assets |
| **E. Era prompt (research gate)** | the 200-clip benchmark from §5; ship the claim kind only on a passing MAE | `inferred_dates.source` value | the benchmark itself is the test; numbers in the design doc |
| **F. Event suggestions (research gate)** | MobileCLIP2-S2 Core ML, sidecar vectors, rung-3 suggestion with distance | sidecar | precision at k on the 18 confirmed events |

A and B are module-internal engine work (Claude decides, Rick weighs in after); C changes what Rick sees and writes the
archive — his call on the sheet and on the four standing questions (Provenance.csv ✓; role list; hard vs soft gate;
July device chain). D is pure evidence and can ride with A.

## 10. Questions for Rick (new; the four from 10/22 still stand)

1. **Film:** are there 8 mm / Super 8 scans in the archive, and where? (§7 cadence analysis is worth building only if so.)
2. **Reference set first:** the 155 live FamilyArchive Masters as the first "Fingerprint Pictures…" run (they are the
   masters everything else should resolve to), then LaCieWorkspace — agree?
3. **The front door:** is `Provenance ▸ Find Master` (phase A, sound only, no schema change) the right first deliverable,
   or should nothing ship until the Provenance sheet (C) exists?
4. **Film-era VLM benchmark:** may the 200-clip benchmark use clips of the family? It runs locally only (rule 13 holds);
   the question is whether its per-clip results (year guesses on named footage) may be written into a doc in the repo.

## Sources

Codebase: `.scratch/provenance_inventory_2026-10-25.md` (file:line for every engine claim). Web:
`.scratch/provenance_web_research_2026-10-25.md` — PDQ / vPDQ / TMK (Meta ThreatExchange; Dalins et al. 2019), VCSL
(CVPR 2022) and VSC23 alignment results, Wang 2003 (Shazam), MobileCLIP2 (Apple), SigLIP 2, DINOv2/v3 licences, Qwen3-VL
report, mlx-vlm issues #2297 / PR #2413, Gemma 4, DEW / "Blind Dates" era-dating results, Gemini 4 Argon and
Antigravity 2.0 announcements and API terms, dvrescue XSD and dvpackager, FCPXML reference, Immich / Mylio / Apple
Photos duplicate rules, ffmpeg `idet`, PRNU literature, C2PA device status.
