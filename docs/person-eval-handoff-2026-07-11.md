# Person Evaluator Handoff — 2026-07-11

## Durable source state

- Branch: `feature/person-recognition-evaluator`
- Head: `3a50a41` (`feat(testing): build Donna benchmark labeling workflow`)
- Based on main `238456c` after a clean rebase.
- Main and Claude worktrees were not modified.

Relevant commits after the rebase:

- `ef13b97` — headless production-engine evaluator
- `8224a90` — reference-free face-presence probe
- `9a7160c` — TestDriver integration and publication safety gate
- `3a50a41` — Donna labeling/export/comparison workflow

## Verified implementation

- VideoScan executable supports `--person-eval` for Vision, ArcFace, dlib,
  Hybrid, and reference-free face presence.
- Standalone evaluator emits JSON and Markdown with face/identity
  precision, recall, F1, accuracy, FP/FN, segment coverage, elapsed time,
  peak RSS, tags, and per-case results.
- Quality publication requires a versioned, balanced, live-engine holdout.
  Fixture, smoke, development, one-sided, errored, or leakage-conflicted
  suites cannot publish.
- TestDriver black-box integration builds VideoScan and runs the generated
  Rick positive/no-person negative sensor.
- Label tooling builds a private review queue from catalog evidence, writes
  an editable CSV, reapplies CSV reviews, validates leakage, and exports
  development or quality manifests.
- Cross-report comparison identifies recovered/regressed cases and metric,
  runtime, and memory deltas.

Verification on 2026-07-11:

- Debug VideoScan build: passed.
- TestDriver integration: passed.
- Full Python suite: 180 passed, 1 optional MLX smoke skipped.
- Focused person-evaluator/tooling tests: 21 passed before the final
  comparison/CSV additions; full discovery afterward reported 180 passed.

## First Donna development baseline

Dataset: six shortest clean videos carrying a human-confirmed Donna catalog
tag. This is development evidence only: zero reviewed negative cases and no
positive timeline annotations.

| Engine | Identity recall | F1 | Elapsed | Peak RSS |
|---|---:|---:|---:|---:|
| Vision | 0/6 (0.0%) | 0.0 | 32.95 s | 140.22 MB |
| ArcFace | 5/6 (83.3%) | 90.9 | 15.84 s | 299.56 MB |

ArcFace recovered five Vision misses. The remaining ArcFace miss had zero
detected faces, indicating a detector/transport/sampling problem rather than
an identity-threshold failure for that case.

The evaluator was subsequently fixed to preserve best non-match distance.
A one-case rerun reported Vision best distance `0.5874368` and correctly
excluded the unannotated positive from segment precision/recall.

## Private generated artifacts

Before shutdown, copy these from `/tmp` into the ignored durable folder:

`output/person-eval-private/2026-07-11/`

Expected files:

- `donna-label-queue.json`
- `donna-label-review.csv`
- `donna-development-vision.json`
- `donna-development-arcface.json`
- `donna-development-vision-report.json`
- `donna-development-vision-report.md`
- `donna-development-arcface-report.json`
- `donna-development-arcface-report.md`
- `donna-vision-vs-arcface.json`
- `donna-vision-vs-arcface.md`

These contain private absolute media paths and must remain ignored/uncommitted.

## Resume procedure

If `/private/tmp/VideoScan-person-eval` disappeared after reboot, recreate the
worktree from the durable branch ref:

```bash
git worktree add /private/tmp/VideoScan-person-eval \
  feature/person-recognition-evaluator
cd /private/tmp/VideoScan-person-eval
```

Regenerate the review queue if the live catalog changed:

```bash
python3 tools/person-eval/build_label_queue.py \
  --catalog "$HOME/Library/Application Support/VideoScan/catalog.json" \
  --poi-root "$HOME/Library/Application Support/VideoScan/POI" \
  --target Donna \
  --output output/person-eval-private/donna-label-queue.json \
  --csv output/person-eval-private/donna-label-review.csv \
  --max-positive 20 --max-negative 20 --max-duration 300
```

## Next action requiring Rick

Open the durable `donna-label-review.csv` in Numbers or Excel. For proposed
hard negatives, fill:

- `targetPerson`: `yes` or `no`
- `anyFace`: `yes` or `no`
- `reviewedBy`: `Rick`
- `set`: `development` or `holdout`
- optional `notes`

Review a subset of confirmed positives too and assign them to development or
holdout. Never place the same `sourceGroup` (or a derived clip from it) in both
training/development and holdout.

Then apply the CSV, export balanced Vision and ArcFace manifests, run both,
and produce the first versioned Donna quality comparison. Only after that
should nightly metrics publication be connected.
