# Synthetic person-search benchmark

## Purpose

This benchmark adds privacy-safe, reproducible identity and media-route tests
without scraping photographs of real people. It does **not** substitute for a
Donna holdout.

The source is
[ControlFace10K](https://huggingface.co/datasets/HuMInGameLab/ControlFace10K),
a CC-BY-4.0 synthetic face-recognition evaluation set containing three poses
of each fictional identity. The source paper is
[SIG: A Synthetic Identity Generation Pipeline](https://arxiv.org/abs/2409.08345).

## What the 100 cases mean

The default build selects 25 synthetic identities. For every identity it
creates four cases:

1. Same identity through an AVFoundation-friendly MP4.
2. The same query through an ffmpeg-routed FFV1 MKV.
3. A different synthetic identity through MP4.
4. The same different-identity query through MKV.

That yields 50 positive and 50 negative **generic identity-verification**
cases. It also yields 50 unique videos; every one is a Donna hard negative
when searched with Donna's real reference gallery.

Synthetic strangers must never be counted as Donna positives. Donna recall
requires held-out Donna videos supplied locally and separated by source
event/tape from reference, training, and development material.

## Demographic and appearance boundary

The first cohort uses the dataset publisher's `Caucasian/female/25|50`
metadata. This is a coarse stress cohort, not an ancestry finding. VideoScan
does not infer that a depicted person is Swedish, Scottish, English, or of any
other ancestry.

ControlFace10K does not publish a blonde-hair label. Therefore the generated
manifest records `appearanceSelectionPerformed: false`. A blonde subset may
be made only through a documented human review of fictional images or a
separately licensed dataset attribute—not by silently presenting ancestry as
something inferred from facial appearance.

`slim` and `petite` cannot be tested with this face-only dataset and, more
importantly, the current native scorer does not consume body-shape evidence.
Those words must not be claimed as active recipe features until a measured,
licensed full-body feature and its own accuracy/bias tests exist.

## Generate locally

The media are generated under ignored `output/`; no family media or external
test imagery is committed.

```bash
python3 tools/person-eval/build_synthetic_identity_corpus.py \
  --accept-license \
  --identity-count 25 \
  --seed 1959
```

The downloader uses HTTP range requests to retrieve only 75 selected PNGs
from the 3.14 GB archive. It renders one 12-second H.264 MP4 and one FFV1 MKV
per identity and writes:

- `manifest.json` — 100 identity/transport cases
- `ATTRIBUTION.json` — source, revision, license, and selection contract
- `identities/` — two references plus one query pose per identity
- `media/` — 50 generated clips
- `runs/<identity>/` — portable gallery/corpus layouts for 25 independent
  four-case `--recipe-calibrate` runs

All paths inside the manifest are relative to the corpus root so a corpus
rendered on the M5 can be copied to the M4 or M1 without rewriting labels.

## Required evaluation lanes

### Generic identity and transport

- Report same-identity true-positive rate and different-identity false-positive
  rate.
- Report MP4 and MKV separately.
- For each semantic pair, assert decoder routes keep the same tier and remain
  within an explicit score tolerance.
- Never tune and report final performance on the same identities.

### Donna-specific hard negatives

- Search all 50 synthetic videos with the frozen Donna reference gallery.
- Expected Donna* count: zero.
- Report Donna? separately; do not hide boundary candidates.
- Add reviewed false positives to the hard-negative training lane only after
  preserving a disjoint evaluation cohort.

### Donna-positive recall

- Rick supplies held-out real Donna clips.
- Split by source event/tape, not extracted frame or derivative filename.
- Measure face-detection recall separately from identity recall.
- Do not publish accuracy if reference/training/evaluation lineage overlaps.

## Acceptance gate for an initial 100-case run

The first run is a baseline, not a release threshold. After it is frozen:

- No decode errors or zero-frame silent negatives.
- No MP4/MKV tier flips for the same semantic pair.
- Every case logs stable case ID, identity IDs, decoder route, numeric score,
  tier, sampled frames, gated faces, and wall time.
- Any threshold is selected on a development split and then evaluated once on
  a disjoint identity split.
- Donna accuracy remains unclaimed until real held-out Donna positives are
  included.

Summarize the captured 25-run log with:

```bash
python3 tools/person-eval/summarize_synthetic_identity_benchmark.py \
  --log output/person-eval-private/controlface100/benchmark.log \
  --output output/person-eval-private/controlface100/benchmark-summary.json \
  --binary-sha256 <sha256> --source-commit <commit>
```

## Baseline — 2026-08-05

The first 100 cases ran headlessly on the M5 with the Release app binary
SHA-256 `3eebe4ae1ef27b4fcb4bc7399684f97944ad38f06b5d6190fa1023754daeee94`
(checkout observed at `420c04b5ba37df6b81a0ba7600b6c0d5b72aa97b`). All 100 clips decoded;
each produced 24 sampled frames and 24 gated faces.

| Cohort | n | Minimum | Median | Maximum | Donna* | Donna* or Donna? |
|---|---:|---:|---:|---:|---:|---:|
| Publisher same-identity poses | 50 | .002 | .144 | .699 | 5 | 8 |
| Different synthetic identity | 50 | .001 | .050 | .238 | 0 | 0 |

Pairwise AUC was .7552. This is useful evidence, but not a valid Donna
accuracy result. In particular, this ArcFace/alignment pipeline does not treat
most ControlFace cross-pose images as the same identity at Donna's thresholds.
An exact-image control scored .996 through MP4 and .999 through MKV, proving
the basic gallery/render/decode wiring and showing that the low cross-pose
scores are a synthetic-domain/identity-consistency result rather than a dead
pipeline.

The decoder-route sensor found a second threshold-changing discrepancy:
synthetic identity `0634f635…` scored .544 (Donna*) through MP4/AVFoundation
and .383 (Donna?) through MKV/ffmpeg from the same source PNG, a .161 delta.
Across all 50 semantic route pairs the median absolute delta was .0115 and the
maximum was .161. The route-invariance gate therefore fails and remains a P0
regression target.

The selected publisher cohort is face-only and visually dominated by short
light-brown/auburn hair. It is a strong similar-face/doppelganger cohort, not
the requested long-blonde/full-body cohort. Add that appearance-focused hard-
negative lane separately; do not relabel this baseline after seeing results.
