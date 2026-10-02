# Archive Angel: 100-file preparation benchmark

This is an opt-in benchmark of the real `ArchiveAngelJob`, not a separate ffmpeg
implementation. It prepares **100 sequential one-file jobs**, with fresh isolated
catalogs; it does not benchmark one 100-entry selection batch or promotion.
Each fixture is marked two-star in the isolated catalog to admit short fixtures;
the user's catalog is not modified. Assessment scoring performance is separate.

## What is compared

- `direct`: read the original from its current volume.
- `ssd-staged`: copy one original to dedicated SSD scratch, then run the job.
- `ram-staged`: copy one original to an already mounted RAM disk, then run it.

Completed companions and plans go to the **same durable SSD** in every mode.
This is an external-prefetch prototype. It does not install the proposed
production inputURLOverride feature or relocate real catalog records.

Per-file timings include staging, record setup, the real preparation job, and
its normal journal writes. Source SHA/mtime validation and benchmark reporting
are outside the per-file timer; the outer runner elapsed time includes them.
Success requires the access companion and no failed/pending steps: an
original-only fallback is not credited as a fast success. Step plans are retained.
Test-host peak RSS is a cumulative host-process high-water mark, NOT combined
ffmpeg/GPU/whole-machine peak memory. Disk backing metadata is recorded; verify
that the named RAM scratch really is RAM before interpreting the comparison.

## Corpus and safe setup

Choose 100 distinct, read-only source files in a JSON array of absolute paths.
Use the same corpus manifest for every mode. Include the media mix (MP4/H.264,
MOV/ProRes, MKV/FFV1+PCM, MXF, AVI/DV), sizes, durations and source volumes that
matter in practice. Small synthetic fixtures are a correctness smoke test, not
evidence of the benefit for hour-long tape recordings. Sources must be at least
eight seconds; use `test_*` names for generated fixtures.

```sh
python3 scripts/angel_benchmark.py prepare \
  --files /absolute/path/100-source-paths.json \
  --output /absolute/path/angel-corpus.json
```

Preparation probes and hashes sources and can warm the OS cache. Do it before
the experiment, not immediately before only one mode. There is no claim of cold
cache and the runner does not purge system caches. Alternate mode order across
nights (direct/SSD/RAM, then RAM/SSD/direct) and repeat before deciding.

Build the tested commit **in Release**, in a dedicated worktree and DerivedData,
with its app tests. Run on a reserved M5/M1 lane, not Rick's interactive M4.
Do not run other model/ffmpeg/performance jobs simultaneously. Ensure sufficient
durable output space: preservation output is NOT bounded by source size ×3.
An 8/16/32GB RAM disk must fit the largest single staged source, plus headroom.
Oversized/staging-failed runs fail explicitly; this prototype does not silently
fall back and label SSD work as RAM work.

```sh
python3 scripts/angel_benchmark.py run \
  --corpus /absolute/path/angel-corpus.json \
  --mode direct \
  --run-root /absolute/ssd/test_angel_runs \
  --project /absolute/worktree/VideoScan/VideoScan.xcodeproj \
  --derived-data /absolute/isolated-release-dd \
  --build-sha EXACT_BUILT_COMMIT \
  --timeout 28800
```

For staging, change `--mode` and supply `--staging-root` pointing to dedicated
SSD or RAM scratch. All modes must use the same `--lossless` choice. No mount,
model unload, schedule installation, archive promotion or source deletion occurs.
Successful per-file staging copies are removed to bound scratch usage; failed
copies and all output companions are retained for diagnosis. Clean up reviewed
test output explicitly after measurements; do not accumulate it indefinitely.

## Overnight use and results

Invoke `run` from the reserved Mac's existing overnight/Aqua execution lane.
It is a **one-shot foreground command**, with a process-group timeout, and
generates a unique run directory and result bundle. Do not wrap it with an
unconditional-restart `launchctl submit` job. If installing a LaunchAgent later,
use explicit one-shot/no-KeepAlive behavior and test it before scheduling.
No recurring schedule is enabled by this change: the corpus and storage/machine
paths must first be selected and a Release smoke run verified.

Each run writes provenance, xcodebuild log, result bundle, per-file checkpoints,
and report.json with pass/fail/incomplete counts. Missing/skipped heavy tests
cannot pass just because xcodebuild exits zero. The evaluator compares only two
complete successful 100-file runs with identical build, machine, corpus,
lossless settings, resolved run root and verified output-storage metadata.
Unknown or different output storage is refused so output-write speed cannot
masquerade as input-prefetch gain:

```sh
python3 scripts/angel_benchmark.py compare \
  --baseline /absolute/path/direct/report.json \
  --candidate /absolute/path/ram/report.json
```

Report total preparation time including staging, median, p95, and percent time
reduction. Also inspect per-step failures, output equivalence, memory and storage
metadata. Codec output need not be byte-identical across encodes, but it must be
playable with the intended streams/duration. A material gain on repeated,
representative runs is evidence for shipping prefetch; a RAM speed-test alone is
not. Partial runs never produce a successful speedup claim.
