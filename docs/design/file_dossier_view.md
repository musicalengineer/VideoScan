# The file dossier view — everything we know about one file, in three layers

Status: in flight — 2026-11-06. Part I (the per-file dossier, layers 1 and 2) is merged with four call sites (the
inspector, the Dossier window, the Results sheet, the Analyze row in Media File Operations) and in Rick's spot test;
layer 3 per file waits on §5 and the DV clock on §7 step 3. **Part II (added 2026-11-06 overnight, Rick's "CA
Observations window") is the collection-scale counterpart, built as an experiment under the streamlined process (Rick
11/06): the window, its three tiers, the scopes and the exact-word search are real; the semantic (embedding) search and
the SigLIP 2 frame search are designed in §II.7 and built only as far as §II.7 says.**

*Rick said "design it" on 2026-11-05 and made his UI calls the same day (§8). This is the per-file view in
`background_service.md` §6 (view 2), reached the way Rick asked for it.*

## 1. What Rick asked for

> "When we select Analyze… we just see them in the MFO window, but when we click on them we don't see all the analysis
> like in the script. Should we make it so we can click on the file in the MFO window and see 1. tech data 2. patterns,
> events 3. corpus wide … showing chevrons like > Technical, then > Events and Patterns, then > Corpus wide observations."
> (2026-11-05, after the 10- and 50-file runs of `tools/dossier-demo`.)

## 2. The shape

- **One view, `FileDossierView`, opened from three places.** CLAUDE.md rule 4: one engine per action.
  1. Clicking a file row in the Dossier window (⌘⇧O, `DossierDashboardView`), the MFO window that Analyze… fills.
  2. The inspector's Dossier section. The new view **replaces** the body of `InspectorDossierView`, which already shows
     the inferred date, captions, OCR and the transcript. Those lines move into layer 2, so nothing is lost and there is
     no second dossier view.
  3. A row in the Results sheet (Content Analysis ▸ Results…), next to "Show in Catalog".
- **Three disclosure groups (the chevrons).** Each one is collapsed to a one-line summary, so a file reads in three
  lines. Opening a group shows its lines.
- **Each line says who said it.** A line carries its source (`ffprobe`, `DV clock`, `8B era`, `Whisper medium`,
  `Rick`) and an **ⓘ** pop-over with the evidence: the frames or windows, the cue, the chain of reasoning.
- **Opening the view runs nothing.** It shows stored facts and observations only, which keeps it instant. Analyze…
  and the background helper run the analyzers, as now, and the view fills in as their results land. A missing line
  says why, for example "not transcribed yet" or "no Whisper model on this Mac".

## 3. Mock (the 1990 Christmas tape; the speech line and the derivative line are illustrative)

```
Christmas_1990_2_hours.dv                                          [Show in Catalog]

▾ Technical — DV camcorder tape · NTSC 720×480 interlaced · 2 h 39 m
    Container      raw DV (DIF)                       → a straight tape capture, no re-wrap      ffprobe
    Video          dvvideo 720×480, 8:9 pixels, 4:3, bottom field first                         ffprobe · mediainfo
    Audio          PCM 48 kHz 2 ch                    → DV 16-bit mode                           ffprobe
    DV clock       none in the tape                   → analog tape through a DV bridge          DV clock ⓘ
    File dates     modified 2003-02-11                → when it was copied, never the shoot      file system
▾ Patterns & events — Christmas · indoor · 1990–95 · speech (English)
    Scene          family around a decorated tree, children and a dog                           8B ⓘ
    Event          Christmas                                                                    8B ⓘ
    Era            1990–1995  (your date: 1990 ✓)                                               8B era ⓘ
    Speech         English — "…open that one next…"                                             Whisper medium ⓘ
    People         2 confirmed                                                                  Rick
    On-screen text none                                                                         8B
▾ Across the collection — 1 derivative · 3 parts of the same tape · re-recording
    Derivatives    Christmas_1990_Part3.mov (same footage, Avid re-wrap)                         sound print ⓘ
    Same tape      Part2-28mins.mov, Part3-47mins.mov                                            chain ⓘ
    Re-recording   content 1990 on DV (DV shipped 1995) → older footage copied onto DV           rule ⓘ
    Date window    1988–1992 from Part 3 (Rick 1990)                                             chain ⓘ
    Event          with 4 files: "Christmas 1990" candidate                                     chain ⓘ
```

The colours follow DECISIONS 2026-11-03: grey and blue, never yellow. A machine claim is never shown as a fact. It
carries its source, and `era.none` never shows as an era (DECISIONS 2026-11-01).

## 4. Where each layer's data comes from (all of it already stored, except where noted)

| Layer | Source | Notes |
|---|---|---|
| Technical | the `files` probe columns plus the interpretation rules | The rules move out of `tools/dossier-demo` into Core (`TechnicalReading`), so the script and the app say the same thing. |
| Technical, DV clock | not stored yet | `background_service.md` §7 step 2, the DV datecode analyzer. Until it lands the line reads "not read yet". |
| Patterns | `provenance_assertions` (era), `captions`, `transcripts`, `people_tags`, `inferred_dates` | The same tables the demo read; read-only. |
| Across the collection | a precomputed **setup index** plus per-file joins | The four rules the 50-file run showed were weak are fixed first (§5). |

## 5. Before the corpus layer: the four fixes from the 50-file run

1. **A capture setup must identify a device.** A generic DV signature (720×480, 48 kHz, 2 ch) is not a camera. A DV
   setup needs the DV clock or the camera's make and model; without them it is a "format group" and bounds no dates.
2. **A camera's span replaces ±2 years.** A camera is used for years, so the window is the span of its dated members,
   widened only by what the evidence allows. A single dated sibling gives a weak hint, never a window.
3. **Our own encodes are transfers.** `Lavf` / HandBrake / `.vs.archive` / `.vs.preserve` outputs describe our tools,
   not the shoot.
4. **Derivatives come first.** Files that are the same footage (matching sound prints, a re-wrap, `vs-edit` /
   `_balanced` / `_repaired`) form one **family** with one original. The family is listed under "Derivatives" and
   never counted as an event or as separate evidence.

Event candidates stop using "same folder" alone; a folder records how Rick filed something, not what happened.

## 6. Tests (rule 8)

- **Logic:** each rule in §5, each layer-1 reading, and the summary lines.
- **Truth:** every line equals its stored row (signer, value, evidence), and a missing analyzer says so in words.
- **Scale:** 100k files. The view opens in under 100 ms (measured; the budget is set from the first measurement), and
  the setup index builds off-main within a stated budget.
- **Isolation:** a file with no probe, an unreadable transcript, an unknown signer.
- **Media matrix:** the technical readings over mp4/h264, mov/prores, mkv/ffv1, mxf, avi/dv (the existing fixtures).
- **A sensor** that the three call sites open the same view (one door).

## 7. Order of work

1. **Layers 1 and 2** (the data exists): `FileDossier` in Core plus `FileDossierView`, wired to the three call sites.
   It replaces `InspectorDossierView`'s body.
2. **The §5 fixes plus layer 3:** the setup index, families, windows and event candidates, each line with its chain.
3. **The DV clock analyzer** (`background_service.md` §7 step 2) fills the DV clock line.

## 8. Rick's calls (2026-11-05)

1. **All three groups start collapsed.**
2. **Clicking a file in the Dossier window does what the other MFO verbs' windows already do** with a clicked file. If
   that proves awkward, we move it to the inspector.
3. **Corpus lines: show what we have** (the sibling files by name), then Rick looks and decides.

---

# Part II — The Observations window: what the machine found, across many files

*Rick, 2026-11-06 evening: "Once we have analyzed everything … how can I see these different levels of Observations,
most interestingly the events and statistics … Where can I query the observations and see what the models have learned?
Do I just poke through the files one at a time?" … "We can do the chevron thing where we see the three tiers > Technical
Metadata > Events > Histographic Corpus … and a search window just for CA which searches metadata, machine observations."
Clarified the same evening: "This is a machine observations only, not a second catalog search." Lives here, not in a
file of its own: the live-docs ceiling is 30 and was full (tests/test_docs_shape.py says: merge into the subsystem's
doc), and this window is layer 3 of the dossier at collection scale.*

## II.0 The rule (pinned by `ObservationsSensorTests`)

**The window shows and searches ONLY what the analyzers observed and concluded.** Never a file name, path, folder,
note, Rick's date, tag, star or any other catalog field — those belong to the Catalog tab's own search. A file name
appears only as the link to where an observation came from. Where a human fact gives context (Rick confirmed this era)
it is shown as the comparison it is ("agrees with your date: N of M"), never as an observation. Machine claims are grey
and blue with their source (DECISIONS 2026-11-03); a machine era is words, never a date, and `era.none` is never an
era (DECISIONS 2026-11-01); an era Rick rejected is never "found". Read-only: the window can never write the catalog,
the journal or the attempts file.

## II.1 The three tiers (the dossier's layers, at collection scale)

| Tier | What it shows (every row: a count, its source in words, an ⓘ with the rule) |
|---|---|
| **Technical** (what the probe read, and what it suggests) | format readings (`TechnicalReading.oneLiner` per distinct probe tuple: "DV camcorder/deck capture, NTSC 720×480"), containers, video codecs, audio codecs, frame sizes, frame rates, scan, camera make/model, encoders, embedded creation dates by decade and by kind (transfer / capture / camera / weak), "not probed yet" / "probe failed". |
| **Patterns & events** (what the models concluded) | machine era by decade words ("early 1990s": N files), no usable era, given up, rejected by you (a comparison); burned-in dates read off the picture; scenes described (files, frames, models) and the "most described" words; speech (files with speech, no speech, words in all) and the "most said" words; on-screen text; people the machine found (detected / suspected, by name) with "confirmed by you" as the comparison; inferred dates by decade; events touching the scope (the related-score ladder's groups, with how many Rick confirmed). |
| **Across the collection** (statistics) | files and contents in scope, duration in all, analyzed by any machine vs nothing yet, coverage per analyzer; machine era vs your date (agrees N of M, the Results sheet's rule); the span of machine eras; models and runs (each caption model, transcript model and era signer: files, first and last run); speech en masse (words, average, longest); observations in the last 24 h. |

Every tier starts collapsed with its one-line summary, as the dossier (Rick's call, 11/05).

## II.2 Scopes

`ObservationsScope`: **everything** (every live file) · **a selection** (`files.id` list, passed as one JSON argument to
`json_each`, so a 20k selection is one bound parameter) · **a folder** (a directory and everything under it, by
`files.directory`) · **a finished pass** (every observation stamped at or after the pass started: `caption_runs.made_at`,
`transcripts.made_at`, `dossiers.processed_at`, `provenance_assertions.at` — exact, no list to keep). The Realtime
window's "See what we learned" uses the last; the catalog's row menu the second; Content Analysis ▸ Observations…
the first.

## II.3 Search

- **One search across all observations** (the field at the top): scene captions, transcripts, on-screen text and
  burned-in dates (SQL `LIKE`, ASCII case-insensitive, `%`/`_` escaped), machine eras (the query against the era's
  decade words "early 1990s" / "1990s" and the years in its range, in Swift over the distinct era values, then the files
  of the matching values), people the machine found (name), event names, and the technical readings (the query against
  each distinct probe tuple's values and interpretation words — "straight tape capture", "ProRes" — then the files of
  the matching tuples). A hit = tier · kind · the observation text (a snippet around the match, with its time in the
  clip) · who said it (model / signer) · the file it came from. Ordered by tier, kind, file name, time; capped at 2,000
  hits and 500 per kind, and the words say when a cap was hit. Double-click reveals the file in the Catalog; Show
  Dossier opens its dossier. Two characters minimum.
- **One filter per tier** (the field in each chevron): narrows that tier's rows by label / value / source, in Swift
  over the rows already on screen (a few hundred).
- `content_text_fts` exists in the schema but nothing populates it (checked 11/06); populating it is a catalog writer
  and waits for Rick. Until then `LIKE` over the captions and transcripts answers in well under a second at 100k rows
  (measured in the truth suite's print line).

## II.4 Sources — every number → its table/column → its test

| Row | Source | Test |
|---|---|---|
| files, contents, duration | `files` (live rows in scope), `count(DISTINCT content_digest)`, `sum(duration_s)` | `ObservationsReportTests.everyCountEqualsADirectCount` |
| format reading, container, codecs, size, rate, scan, camera, encoder | `files.container / video_codec / audio_codec / stream_type / probe_extra.{resolution,frameRate,scanType,audioSampleRate,originMake,originModel,originEncoder}` grouped in SQL, interpreted once per distinct tuple by `TechnicalReading` | same |
| embedded dates by decade and kind | `files.embedded_created_at`, `TechnicalReading.classifyCreationTime` | same |
| machine era rows | `provenance_assertions` classified by the Results sheet's `verdicts` SQL (one engine: found / rejected / no usable era / given up), words by `AnalysisResultsReport.eraWords` | same + `eraNoneIsNeverAnEraAndARejectedEraIsNeverFound` |
| burned-in dates | `provenance_assertions.field = 'ocr.date'`, machine signers, not rejected | same |
| scenes described, on-screen text | `captions` by `kind` (`scene`, `ocrText`, `ocrDate`), `caption_runs.model` | same |
| speech | `transcripts.text` (`''` = ran, no speech), words = spaces + 1 | same |
| people found | `people_tags.kind IN ('detected','suspected')`; `confirmed` is the comparison | same |
| inferred dates | `inferred_dates.date_at / reason` | same |
| events | `events` ∩ `event_members.digest` in scope | same |
| search hits | the row the hit came from; the test proves each hit's text contains the query or derives from a matching era / tuple | `ObservationsSearchTests.everyHitContainsOrDerivesFromTheQuery` |
| never catalog fields | the search SQL names none of `filename / full_path / directory / user_notes / user_dates / workflow_tags / stars / user_places` | `ObservationsSensorTests` + `aFileNameOrNoteIsNeverAHit` |

## II.5 What is NOT shown, and why

Rick's own dates, tags, notes, stars, places and confirmed people as observations (they are his, not the machine's;
they appear only as comparisons). Face-recognition vectors and sound prints (not readable as words). Frame-by-frame
window eras (`era.yearRange`; the fused era is the verdict). Removed files' observations in "everything" (a removed
file is not the collection; a selection that names one still shows it, greyed). Anything the FTS index would add
(not populated).

## II.6 Shape in code

Core `Observations/`: `ObservationsScope`, `ObservationsReport` (pure value: three `Tier`s of `Group`s of `Row`s, each
row a count with source words and an ⓘ), `ObservationsReport.build(reader:scope:now:)`, `ObservationsSearch`.
Store: `CatalogObservationsReading` (SELECT-only seam, implemented on `GRDBReader` alone) with the scope as one CTE.
App `Observations/`: `ObservationsLoader` (closures, `production(model:)`, memoised per model) · `ObservationsStore`
(@MainActor feature store, detached reads, newest request wins, cancellation on close) · `ObservationsWindow` +
`ObservationsWindowController.shared.show(model:scope:source:)` — the ONE door the three entry points use. No
`extension VideoScanModel`; no O(records) work in a body; reveal through `showInCatalog`, the dossier through
`FileDossierLoader.production`. Memory, worst case: one report (a few hundred rows), one hit list (≤ 2,000 × ~400 B),
the word histograms (≤ 20,000 distinct keys while counting, 25 kept each).

## II.7 Using the hardware: semantic search and SigLIP 2 (Rick, 11/06: "use all the power we have")

1. **Text embeddings over every observation** (captions, transcript sentences, OCR, era/event phrases): a small
   on-device embedding model through MLX (`venv-mlx`), vectors kept in an **in-memory index** (100k × 384–1024 dims
   ≈ 150–400 MB fp32; the Ultra has 96 GB) and on disk as a **rebuildable cache** beside the catalog
   (`background/observation-embeddings/<model id>.npy` + a `.jsonl` of (content SHA-256, kind, seq, text-hash)),
   never a catalog table (no schema change without Rick). Exact cosine search on the GPU (MLX matmul), milliseconds
   per query at 100k rows; no ANN index needed at this scale. A semantic hit shows the observation text, its analyzer,
   its file and the similarity; the exact-word search stays beside it. The build is an MFO job with START/OUTCOME,
   Pause/Stop, utility QoS, incremental by text-hash. **Status 11/06: designed, not built** — no embedding model is on
   this Mac (`~/.cache/huggingface/hub` holds the Qwen VLMs and Whisper only; `mlx_embeddings` and
   `sentence_transformers` are not installed in `venv-mlx`). First candidates to fetch and measure:
   `mlx-community/bge-small-en-v1.5-mlx` (33M params, 384 dims, MIT) or `mlx-community/all-MiniLM-L6-v2-4bit`.
2. **SigLIP 2 text→frame search** ("a birthday cake with candles" finds the frames): keyframes the analyzers already
   rip where cached, else a few per file through the existing ffmpeg path (read-only on media), embedded with SigLIP 2
   B/16 (Core ML `palmier-io/siglip2-base-coreml`, or MPS via `transformers`; the 11/05 research report, rows 23–24);
   frame vectors cached keyed by (content SHA-256, timestamp, model id); a hit shows the thumbnail, file, time and
   similarity. **Status 11/06: designed, not built** (no SigLIP 2 weights on this Mac; the exact-word window came first,
   as asked). The honest order: 1 → measure → 2 → hand-check ten queries on real footage and write down what it got wrong.
3. **Clustering for tier 3** (recurring scenes / places / topics): k-means over the observation vectors off-main,
   cached by catalog generation. Designed, not built.

## II.8 Hallie (design only)

Hallie answers "how many videos from the 1990s show a dog", "when did we film at the Cape", "find Dad telling a story"
through the SAME engine: an `AnswerPlan` of (scope, tier, query) → `ObservationsReport` / `ObservationsSearch`, the
answer carrying its evidence rows (each hit's text, source and file). Decade words resolve through `MachineEraResolver`
(a machine era is never a date in the answer either). Not built.

## II.9 Tests (streamlined, Rick 11/06: "you don't need tons of tests, this is kind of an experiment")

Kept: truth (every shown count equals a direct SQL count written another way; every hit contains or derives from its
observation; a file name or a note is never a hit; `era.none` never an era; a rejected era never found), the read-only
guarantee and the one-door sensor, the mockups rendered from the real view. **Not done** (to harden if the experiment
survives): the 100k scale budget as a test (only measured by hand), the media matrix, poisoned rows, the store's
cancellation and race tests, the Realtime hand-off's timing, UI tests of the entry points.
