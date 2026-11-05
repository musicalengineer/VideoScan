# Dossier demo

A demo you can watch in Terminal. It takes about ten family media files and shows what each of the three dossier layers in `docs/design/background_service.md` Part A learns about each one:

1. **Technical** (§1): facts read from the bytes by ffprobe, mediainfo, stat and dvrescue (the DV camcorder clock), each with a line on what it suggests.
2. **Perceptual** (§2): Qwen3-VL-8B-4bit (the era job's model) looks at 4 stills and gives the scene, the event type, any visible text, any burned-in date, and an era guess with a reason. The per-still date OCR uses the seated prompt. mlx_whisper transcribes the first minute, but only if a Whisper model is already downloaded. Beside each file the demo shows what the catalog already holds: the background service's era, captions, the transcript, people tags and Rick's date.
3. **Corpus** (§3): deterministic joins across the picked files, each with its evidence chain. These are the capture setups, date windows a hard date gives its setup siblings, the model's era against the hard dates, re-recordings, and event candidates.

At the end it prints a summary table and the time each stage took. It also writes `dossier.md` and a self-contained `dossier.html` (stills embedded) to `.scratch/dossier-demo/<timestamp>/`.

## Run it

Double-click `run.command`, or run `open -a Terminal tools/dossier-demo/run.command`. Options are passed through to the script:

```
tools/dossier-demo/run.command --n 10 --seed 1234
tools/dossier-demo/run.command --files /path/a.dv /path/b.mov
tools/dossier-demo/run.command --skip-models      # layers 1 and 3 only, seconds
```

The script runs on the `venv-mlx` interpreter. If you pass no `--seed`, the run prints the seed it used, so you can repeat the same pick.

## Rules it keeps

- **Local only.** The Hugging Face libraries are forced offline, models load from the local snapshot, and nothing is downloaded.
- The catalog is read only through `scripts/catalog_db.connect()`, which opens it read-only. Media is only read.
- Everything written goes under `.scratch/dossier-demo/`, which git ignores. That covers the report, the stills and the temporary audio.
- The model sees pixels only, never the file's technical facts (DECISIONS 2026-10-31).
- It writes no observations. It shows what the background service would produce; it does not produce it.
- Each model is loaded once and freed before the next one. If a stage fails on a file, the demo prints why and carries on.

The pure parts (interpretation rules, setup clustering, date windows, picking) are tested in `tests/test_dossier_demo.py`.
