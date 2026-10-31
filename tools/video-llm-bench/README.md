# Video-LLM benchmark harness (`tools/video-llm-bench`)

Phase 0 of `docs/design/video_llm_lab_2026_10_30.md` §4: a Judge that scores a video-model
*approach* against ground truth the catalog already holds, starting with **`a0-py`** — today's
captioner (Qwen2.5-VL-3B-Instruct-4bit, stills, the three prompts `MLXVLMCaptionRunner.dossier`
sends) run through `mlx-vlm` in `venv-mlx`. Every later approach is compared to A0's numbers.

It follows `tools/qwen-bench`'s discipline: a run record pins model tag + weights digest, prompt
hashes, sampler id, git SHA, corpus hash, host, seed, library versions and timings; per-clip raw
output stays in `.scratch/`; only aggregates reach the repo.

## What stays where

| Lives in `.scratch/bench/` (never committed) | Lives in the repo |
|---|---|
| `catalog-copy.sqlite` — a `.backup` copy of the catalog, opened read-only (`mode=ro`) | `bench.py`, this README |
| `manifest.json` — the frozen corpora: digests, **paths**, strata, truth values | `tests/test_video_llm_bench.py` |
| `runs/<run id>/run.json`, `progress.json`, `clips/<digest>.jsonl` — raw model text per (clip, frame, prompt) | `docs/reviews/video_llm_benchmarks.md` — aggregates only (DECISIONS 2026-10-26) |

The Markdown never carries a path, a content digest (not even a prefix), a family name or raw model
text; `test_markdown_carries_no_path_digest_or_model_text` greps for exactly that. Hashes that
identify the run (weights, corpus, git) are shown as their first 12 hex characters.

## Commands

All paths absolute; the catalog copy is the **only** sanctioned way to read the catalog from here
(`.backup` from the sqlite3 shell; never open the live file):

```sh
sqlite3 "$HOME/Library/Application Support/VideoScan/catalog.sqlite" ".backup '<worktree>/.scratch/bench/catalog-copy.sqlite'"

venv-mlx/bin/python3 tools/video-llm-bench/bench.py validate-corpus \
  --catalog <worktree>/.scratch/bench/catalog-copy.sqlite \
  --out     <worktree>/.scratch/bench/manifest.json          # [--seed 20261030 --camera-target 200 --ocr-target 100]

venv-mlx/bin/python3 tools/video-llm-bench/bench.py run \
  --manifest <worktree>/.scratch/bench/manifest.json --approach a0-py --frames 5 \
  [--corpus ocr|era] [--limit N] \
  --out <worktree>/.scratch/bench/runs/<timestamp>-a0-py       # resume-safe: rerun the same command to continue

venv-mlx/bin/python3 tools/video-llm-bench/bench.py summarize \
  --run <worktree>/.scratch/bench/runs/<timestamp>-a0-py \
  --manifest <worktree>/.scratch/bench/manifest.json \
  --out docs/reviews/video_llm_benchmarks.md                   # overwrite; also printed to stdout
```

Tests (no model, no media, no catalog): `venv/bin/python3 -m pytest tests/test_video_llm_bench.py tests/test_video_llm_bench_a1.py`.

## Corpora (`validate-corpus`)

* **ERA** — every `user_dates` row with a value and a reachable live video file (stratum
  `rick-dated/<decade>`), plus a stratified sample of camera-dated files (`camera/<decade>/<codec>`,
  target 200, seed fixed, every non-empty stratum gets at least 8 or all it has, the rest
  proportional). `files.embedded_created_at` counts as truth **only for camera-native codecs**
  (hevc, h264, mjpeg, dvvideo, mpeg4, svq3, h263); ProRes/FFV1/DNxHD `creation_time` is a transfer
  stamp (DateTriangulator: "export stamp … set aside as ingest") and is excluded.
* **OCR** — digests with an `ocrDate` caption and a `DateTriangulator` row in `inferred_dates`
  whose verdict is an OCR verdict: the `on-screen date YYYY-MM-DD` named in `reason` when present,
  else the majority parsed date of the existing `ocrDate` captions. Digests whose only OCR output
  is the `!!!!…` failure mode have no OCR truth and are not in the corpus.

The report prints counts per stratum, the pool each was drawn from, how many `user_dates` rows
were found and reachable, and the corpus hash (path-independent: digests + strata + truth).

## Run (`run --approach a0-py`)

Per clip: N stills from the middle 90 % (`framesEvenlySpaced`), ripped by ffmpeg to 448×448
letterboxed PNGs; each still gets the three prompts (date / scene / text, verbatim from
`CaptionRunner.swift`, same per-prompt `max_tokens` / temperature, same seed per clip); one JSONL
line per (clip, frame, prompt) with the raw text, elapsed seconds, counters and the parsed fields
(ISO dates, 4-digit years, decade mentions, degenerate flag). Frames are deleted after the clip;
one PNG and one generation are in flight at a time; `mx.clear_cache()` after every clip. Peak RSS
is recorded per clip. A clip is complete only when its file ends with `clip_done`; a partial file
(crash) is redone on resume. `progress.json` is rewritten after every clip.

## Summarize (`summarize`)

* **ERA** — best single year per clip: the year of every parsed calendar date in the date/text
  answers weighs 3, every explicit 4-digit year in any answer weighs 1, a decade mention weighs 1
  ("1990s" → 1995; early/mid/late → +2/+5/+7); heaviest wins, tie → median. No candidate → **no
  answer**, excluded from MAE and reported as a rate. Metrics: n, answered, no-answer rate, MAE,
  median error, share within ±5 y of answered and of all — overall, per family, per decade, per
  stratum.
* **OCR** — any-frame exact (some date answer parses to the truth date), majority exact, year
  match, schema-valid (≥ 1 date answer parsed), frames-with-a-date rate, degenerate-frame rate.
* **Cost** — model load s, s/frame (three prompts), s/generation, ffmpeg s/frame, peak RSS, host,
  weights digest, mlx-vlm / mlx versions.

## Run-record fields (`run.json`)

`run_id`, `started_at`, `approach_id`, `sampler_id`, `frames_per_clip`, `frame_side_px`,
`frame_letterbox`, `prompts_sha256{date,scene,text}`, `system_prompt_sha256`, `gen_params`,
`mlx_seed`, `manifest_path`, `manifest_seed`, `corpus_hash`, `era_corpus_hash`, `ocr_corpus_hash`,
`corpus_filter`, `limit`, `host`, `platform`, `python`, `ffmpeg`, `git_sha`, `bench_source_sha256`,
`model`, `model_dir`, `weights_sha256` (sha256 over the sorted (name, sha256) of every
safetensors file), `weights_bytes`, `load_s`, `mlx_vlm_version`, `mlx_version`,
`transformers_version`, `resumed[]`.

Per result line: `digest`, `frame_index`, `at_s`, `prompt_kind`, `prompt_sha256`, `raw_text`,
`elapsed_s`, `rip_s`, `error`, `counters{prompt_tokens, generation_tokens, generation_tps,
peak_memory}`, `parsed{dates, years, decades, degenerate}`.

## Approach `a1-py` — windows + strict JSON contract (design §5 row A1)

Same model, weights, loader and seed as A0. What changes:

* **Sampler** (`plan_windows`): up to 3 chronological windows inside the middle 90 % — one at its start,
  one centred on its middle, one at its end — each ≤ 60 s and ≤ span / 3, so they never overlap. A
  middle-90 % span under 30 s gets one window; zero/non-finite duration gets none. N frames per window
  at the centres of N equal sub-intervals (fewer if closer than 0.25 s). Sampler id
  `windows-3x<N>-max60s-middle90`.
* **One multi-image generation per (window, family)**: the N frames go into one prompt
  (`apply_chat_template(..., num_images=N)`, mlx-vlm 0.5.0 accepts a list for Qwen2.5-VL). Families
  `era` and `roomFeatures`, schemas from design §3.3 written into the prompt (`A1_PROMPT_REVISION`).
  ERA-corpus clips only.
* **Fail-closed decoding** (`decode_contract`): a Python mirror of Swift `ContractDecoder`
  (`VideoScanCore/ModelLab/ApproachOutputContracts.swift`). The raw text must be exactly one JSON
  object; unknown keys, wrong types, null, missing keys, wrong `family`, years outside 1900…2100,
  a reversed range, `selfConfidence` outside 0…1, lists over 64, responses over 64 KB → `schemaInvalid`
  with a reason. No fence stripping, no "find the first `{`", no regex rescue. Stricter than Foundation
  in two corners (NaN/Infinity, duplicate keys), both fail-closed. `test_python_contract_keys_match_the_swift_contract`
  pins the key sets to the Swift file.
* **OCR**: OCR-corpus clips get A0's `date` prompt verbatim, one frame per call, on every window frame
  (records shaped like A0's, scored by the same `score_ocr_clip`).

Choosing N: `run --approach a1-py --smoke 3 --frames {4,6,8}` (first ERA clip ≥ 60 s of three distinct
decades); pick the largest N whose window answers are ≥ 90 % schema-valid.

```sh
venv-mlx/bin/python3 tools/video-llm-bench/bench.py run --approach a1-py --frames 6 \
  --manifest <worktree>/.scratch/bench/manifest.json --model-dir <weights dir> \
  --out <worktree>/.scratch/bench/runs/<id>-a1-py
venv-mlx/bin/python3 tools/video-llm-bench/bench.py summarize --manifest … \
  --run <a0 run dir> --run <a1 run dir> --out docs/reviews/video_llm_benchmarks.md
```

Scoring (`summarize_a1_run`): a schema-valid `era` window is an answer. Per clip the range is
[median FROM, median TO] over its valid windows, re-decoded from the raw text (the stored flag is never
trusted); the midpoint is the point estimate for MAE / ±5 y; *inside* = truth within the range;
median range width is reported. roomFeatures: schema-valid rate, vocabulary size (distinct lower-cased
strings), top 20 — printed only for strings that are lowercase letters, spaces and hyphens in their
raw form (anything with a capital, digit or punctuation is counted, never printed). An "A1 vs A0"
three-line reading is generated from the numbers when both runs are passed.

Per window result line: `digest`, `window_index`, `window`, `frame_times_s`, `frames_shown`, `family`,
`prompt_sha256`, `raw_text`, `elapsed_s`, `rip_s`, `error`, `counters`, `schema_valid`,
`schema_invalid_reason`, `decoded`.
