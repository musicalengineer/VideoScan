# Person Finder Test Harness

This folder contains a manifest-driven CLI runner for the person-finder engine.

## Why this shape

The project does not expose many pure unit seams yet. The highest-value automated
checks today are:

- a media-free smoke test that validates the Python recognizer can start, import
  dependencies, apply its memory guard, and emit valid JSON
- optional fixture-driven integration tests against known reference photos and clips
- the engine invoked the same way the app invokes it

That gives you repeatable regression coverage without embedding test code in the
shipping app.

## Run all tests

```bash
cd /Users/rickb/developer/VideoScan
python3 ./tests/run_personfinder_tests.py
```

If your local env uses a different interpreter, update `defaults.python` in
`tests/personfinder_cases.json`, or just run the harness with the interpreter
you want to use. By default it reuses `sys.executable`.

## Run one case

```bash
python3 ./tests/run_personfinder_tests.py --case engine_self_test
```

## Write a JSON report

```bash
python3 ./tests/run_personfinder_tests.py \
  --json-report ./tests/last_report.json
```

## Manifest

Cases live in `tests/personfinder_cases.json`.

Each case can override the defaults:

- `python`
- `script`
- `ref_path`
- `video`
- `threshold`
- `frame_step`
- `min_conf`
- `pad`
- `min_duration`
- `timeout_sec`
- `max_rss_mb`
- `self_test`

Basic expectations supported now:

- `error`
- `faces_detected_min`
- `hits_min`
- `segments_min`
- `best_dist_max`

## Private fixtures

The committed manifest includes a no-media `engine_self_test` case and may also
include fixture cases that reference private videos under `tests/fixtures/videos/`.

If those private files are absent, the harness reports those cases as `SKIP` and
still returns success as long as the runnable cases pass.

## Recommended direction

1. Keep the smoke test runnable from a clean checkout.
2. Add calibrated regression cases around known fixtures once outputs stabilize.
3. Have Xcode test targets invoke this same harness if you want one-button runs.
4. Keep long-running fixture tests out of release UI code.
