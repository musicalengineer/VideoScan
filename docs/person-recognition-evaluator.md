# Person Recognition Evaluator

**Status:** Initial implementation
**Last updated:** 2026-07-10
**Author:** Rick + Codex
**TL;DR:** A standalone evaluator labels videos independently of the recognition code, invokes a configured engine, and reports face-presence, identity-presence, segment, and performance metrics. VideoScan's headless engine adapter is the next integration seam.

## Purpose

The evaluator answers two separate questions:

1. Does this video contain any detectable human face?
2. Does this video contain the target person (initially Donna)?

It is intentionally outside XCTest and outside the GUI. Accuracy runs can take
minutes or hours, depend on private media, and should produce a durable score
even when no product assertion has failed.

The headline score is identity F1 on a 0–100 scale. Precision, recall, false
positives, false negatives, face-presence performance, screen-time overlap,
runtime, and memory remain visible so the headline cannot hide an engine that
simply predicts "Donna" for everything.

## Architecture

```text
private labeled manifest
        |
        v
standalone person_eval.py ----> configured engine command
        |                              |
        |                              v
        +<--------------------- per-video result JSON
        |
        +---- report.json (automation / future metrics)
        +---- report.md   (human morning review)
```

The engine command is an adapter, not an alternate recognizer. The intended
production adapter invokes a narrow headless mode in the built VideoScan
executable, which in turn calls the same Vision, ArcFace, dlib, or hybrid
functions used by `PersonFinderModel`. This prevents benchmark drift.

The headless app adapter also supports a reference-free face-presence probe:

```bash
/path/to/VideoScan.app/Contents/MacOS/VideoScan \
  --person-eval --face-presence-only --video /path/to/video.mov
```

It uses the production Vision decoder, frame sampler, orientation handling,
face detector, watchdog, and counter, but supplies no identity feature prints.
Every observed face is therefore counted without being assigned a name.

During evaluator development, a case may name a checked-in result JSON instead
of launching an engine. That mode makes scoring tests deterministic and does
not claim recognition accuracy.

## Manifest contract

`schemaVersion` is required. Paths are resolved relative to the manifest.
Private manifests and media do not need to be committed.

```json
{
  "schemaVersion": 1,
  "suite": "Donna golden holdout",
  "publication": {
    "tier": "quality",
    "datasetVersion": "donna-golden-v1",
    "holdout": true
  },
  "engine": {
    "name": "ArcFace",
    "person": "Donna",
    "referencePath": "/private/path/to/donna/references",
    "timeoutSeconds": 3600,
    "command": [
      "{app}",
      "--person-eval",
      "--engine", "arcface",
      "--person", "{person}",
      "--references", "{references}",
      "--video", "{video}"
    ]
  },
  "cases": [
    {
      "id": "donna-1988-birthday",
      "video": "videos/donna_1988_birthday.mov",
      "tags": ["positive", "1980s", "group", "adult"],
      "expected": {
        "anyFace": true,
        "targetPerson": true,
        "segments": [{"start": 12.0, "end": 34.0}]
      }
    },
    {
      "id": "dan-hard-negative",
      "video": "videos/dan.mov",
      "tags": ["negative", "hard-negative", "family-similarity"],
      "expected": {"anyFace": true, "targetPerson": false}
    }
  ]
}
```

Engine stdout must be one JSON object. The evaluator accepts the existing
Python engine's snake-case keys as well as the planned Swift adapter keys:

```json
{
  "facesDetected": 24,
  "hits": 8,
  "bestDistance": 0.31,
  "segments": [{"start": 12.0, "end": 18.0}],
  "elapsedSeconds": 2.5,
  "peakRSSMB": 512,
  "error": null
}
```

## Metrics

- **Face presence:** video-level precision, recall, F1, accuracy, FP/FN.
- **Identity presence:** the same classification metrics for the target person.
- **Segment recall:** labeled target-person screen time overlapped by detections.
- **Segment precision:** predicted screen time overlapping labeled screen time.
- **By-tag identity metrics:** decades, age, blur, group scenes, and especially
  `family-similarity` hard negatives.
- **Performance:** total wall time and maximum reported peak RSS.

An absent denominator is reported as `null`/`n/a`, never as a misleading 0% or
100%. The golden suite should contain positive and negative cases.

## Dataset discipline

Use two sets:

- **Development set:** visible during threshold and model tuning.
- **Golden holdout:** scored periodically but never used to choose reference
  frames, thresholds, or training examples.

Do not split frames from the same source recording between training references
and the golden holdout. Near-duplicate leakage measures memorization rather
than identity generalization.

Recommended fixture categories:

- clear Donna positives;
- difficult Donna positives (age, pose, glasses, blur, occlusion, old media);
- easy negatives with people present;
- hard-negative relatives and lookalikes;
- no-person scenes;
- group scenes;
- decade and age bands;
- videos where context suggests Donna but she is absent.

Private media and labels should live outside git or in a gitignored private
fixture root. Stable IDs, labels, and non-sensitive tags can be committed if
desired.

### Building the private review queue

Catalog confirmations seed positive candidates; other-family detections only
seed *possible* hard negatives and remain unlabeled until a human reviews them:

```bash
python3 tools/person-eval/build_label_queue.py \
  --catalog "$HOME/Library/Application Support/VideoScan/catalog.json" \
  --poi-root "$HOME/Library/Application Support/VideoScan/POI" \
  --target Donna --output /tmp/donna-label-queue.json \
  --csv /tmp/donna-label-review.csv
```

The queue excludes long/derived media from holdout eligibility, groups likely
duplicates, and flags a source appearing under conflicting suggestions. After
editing the CSV in Numbers/Excel, apply it back to the queue:

```bash
python3 tools/person-eval/apply_label_csv.py \
  --queue /tmp/donna-label-queue.json \
  --csv /tmp/donna-label-review.csv \
  --output /tmp/donna-reviewed-queue.json
```

Then export a development or quality manifest:

```bash
python3 tools/person-eval/label_queue_to_manifest.py \
  --queue /tmp/donna-label-queue.json \
  --output /tmp/donna-vision.json --engine Vision \
  --references "$HOME/Library/Application Support/VideoScan/POI/donna" \
  --dataset-version donna-development-v1
```

`--quality --set holdout` additionally requires a balanced, reviewed,
holdout-eligible set with no unresolved leakage warnings.

## Usage

Deterministic evaluator self-test:

```bash
python3 tools/person-eval/person_eval.py \
  tests/fixtures/person_eval/example_manifest.json \
  --json /tmp/person-eval.json \
  --markdown /tmp/person-eval.md
```

For a live VideoScan manifest, supply the current build without editing the
manifest:

```bash
python3 tools/person-eval/person_eval.py private/donna-manifest.json \
  --app /path/to/VideoScan.app/Contents/MacOS/VideoScan \
  --json /tmp/donna-eval.json --markdown /tmp/donna-eval.md
```

The checked-in production-pipeline smoke suite uses generated Rick-positive
and no-person-negative media, so it is safe to run anywhere the app builds:

```bash
python3 tools/person-eval/person_eval.py \
  tests/fixtures/person_eval/videoscan_rick_smoke.json \
  --app /path/to/VideoScan.app/Contents/MacOS/VideoScan \
  --json /tmp/person-eval-smoke.json \
  --markdown /tmp/person-eval-smoke.md
```

This is an integration sensor, not evidence of family-recognition quality. The
private Donna holdout will supply that evidence once labeled.

Python tests:

```bash
python3 -m unittest tests/test_person_eval.py
```

## Nightly integration seam

The JSON report is deliberately additive and stable enough for a later nightly
row. Suggested fields are:

```json
{
  "person_eval_score": 81.4,
  "person_eval_precision": 0.86,
  "person_eval_recall": 0.77,
  "person_eval_family_fp": 2,
  "person_eval_elapsed_s": 1842,
  "person_eval_engine": "ArcFace",
  "person_eval_suite": "donna-golden-v1"
}
```

Nightly publication is intentionally deferred until the real VideoScan adapter
and a useful private holdout exist. Empty or fixture-only suites must never
publish a production-looking accuracy score.

The evaluator enforces that boundary. A report is `publishEligible` only when
the manifest explicitly declares a versioned quality-tier holdout, all cases
ran a live engine, the suite contains both identity-positive and
identity-negative cases, and no result reports an engine error. Development
and smoke suites can never publish a production quality score. Automation can
add `--require-publishable`; an ineligible report is still written for
diagnosis, but the command exits 4 so it cannot be mistaken for a nightly score.
