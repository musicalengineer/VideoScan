# Person Finder Test Harness

This folder now contains a manifest-driven CLI sanity runner for the person-finder engine.

## Why this shape

This project's real seams are not pure unit functions yet. The highest-value automated checks today are fixture-driven integration tests:

- reference photo folder in `unit_tests/photos/`
- known video clips in `unit_tests/videos/`
- engine invoked the same way the app invokes it

That gives you repeatable regression coverage without embedding test code in the shipping app.

## Run all sanity tests

```bash
cd /Users/rickb/dev/VideoScan
./venv/bin/python ./unit_tests/run_personfinder_tests.py
```

If your local env uses a different interpreter, update `defaults.python` in
`unit_tests/personfinder_cases.json`, or just run the harness with the interpreter
you want to use. By default it reuses `sys.executable`.

## Run one case

```bash
./venv/bin/python ./unit_tests/run_personfinder_tests.py --case donna_short_clip
```

## Write a JSON report

```bash
./venv/bin/python ./unit_tests/run_personfinder_tests.py \
  --json-report ./unit_tests/last_report.json
```

## Manifest

Cases live in `unit_tests/personfinder_cases.json`.

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

Basic expectations supported now:

- `error`
- `faces_detected_min`
- `hits_min`
- `segments_min`
- `best_dist_max`

## Recommended direction

This is a good idea.

The right progression is:

1. Start with sanity/integration tests around known fixtures.
2. Add a few calibrated regression cases once outputs stabilize.
3. Have Xcode test targets invoke this same harness if you want one-button test runs.
4. Keep test logic out of release UI code.

Do not put long-running fixture tests directly into the shipping app UI unless you are explicitly building an internal diagnostics panel.
