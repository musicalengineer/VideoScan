# find_donna_scan.py — batch "find Donna" volume driver

Batch driver over the person-eval CLI (POI cycle 03 minimum-hits rule,
schema v2). Walks whole volumes or folders, evaluates every video file
with the Release VideoScan binary (ArcFace, production Donna references),
and produces a curation report of Donna-candidate clips.

Python 3 stdlib only. No venv required.

## Prerequisite: a Release binary

The driver invokes the app binary's `--person-eval` entry point. Build it
once (Release — production parity for recognition results):

```
xcodebuild build -project VideoScan/VideoScan.xcodeproj \
    -scheme VideoScan -configuration Release
```

The script auto-discovers the newest Release build (worktree DerivedData,
`~/Library/Developer/Xcode/DerivedData`, XcodeRAM, `/Applications`), or
take control explicitly with `--binary <...>/VideoScan.app/Contents/MacOS/VideoScan`
or `VIDEOSCAN_BIN=<path>`.

## Usage

Scan a whole volume:

```
python3 scripts/find_donna_scan.py /Volumes/MyBook3Terabytes \
    --out ~/DonnaScan/mybook3t
```

Multiple roots, custom floor:

```
python3 scripts/find_donna_scan.py /Volumes/Seagate2TB /Volumes/Crucial2TB \
    --out ~/DonnaScan/pass1 --min-hits 5
```

Quick smoke (first 10 files only):

```
python3 scripts/find_donna_scan.py ~/SomeFolder --out /tmp/smoke --limit 10
```

Resume after Ctrl-C or a crash — just rerun the same command. Resume is
the default: every processed file is one line in `<out>/scan-progress.jsonl`,
and already-recorded paths are skipped on restart. `--no-resume` archives
the old log (`.bak-<timestamp>`) and starts fresh.

Flags:

| Flag | Default | Meaning |
|------|---------|---------|
| `--out DIR` | (required) | report directory |
| `--frame-step N` | 10 | sample every Nth frame (lower = slower, more hits) |
| `--min-hits N` | 7 | confirmation floor (POI C3 graded value) |
| `--limit N` | off | max files this session (testing) |
| `--resume / --no-resume` | on | skip already-recorded paths |
| `--jobs N` | 1 | parallel evaluations — **leave at 1 for HDDs** |
| `--binary PATH` | auto | Release VideoScan binary |
| `--person NAME` | Donna | evaluated person label |
| `--references DIR` | `~/Library/Application Support/VideoScan/POI/donna` | reference photos |

Execution is sequential by default on purpose: archive volumes are mostly
spinning disks, and parallel decode makes seek thrash worse than any CPU
win. `--jobs` exists for SSD roots only.

## Outputs

- `<out>/scan-progress.jsonl` — one JSON line per file: `path`, `presence`,
  `totalHits`, `duration`, `elapsed`, `error`. The resume log AND the raw
  data of record. Errors (unreadable file, CLI failure) are recorded here
  and never abort the run.
- `<out>/donna_candidates.csv` — `path, presence, totalHits, duration`,
  confirmed rows first, then near-misses, each sorted by hits descending.
- `<out>/donna_candidates.html` — self-contained page (no external assets):
  confirmed clips as `file://` links, then a **near miss** section, then
  errors.

## What confirmed / near-miss mean

- **Confirmed** — `presence == "confirmed"`: the clip accumulated at least
  `--min-hits` (default 7) ArcFace matched face observations against the
  production Donna references. This is the C3 minimum-hits rule, graded
  BA 0.615 / FN 0 on the eval corpus. It is a *candidate* list, not truth.
- **Near miss** — presence `none` but `totalHits >= 3`. The floor rejected
  it, yet something in it repeatedly matched Donna's references. These are
  curation gold either way (see below).

## Curation guidance (what to do with the report)

1. **Confirmed + really Donna** → training-pool additions (more reference
   diversity across ages/lighting).
2. **Confirmed + NOT Donna** → hard negatives. Label them; these are
   exactly the lookalikes a future classifier (C4) needs.
3. **Donna clips you know of that the scan MISSED** → sealed-holdout gold.
   Selection-bias note: any positive *found by the matcher* is by
   construction biased-easy for that matcher. Holdout positives should
   prefer independent finds — clips you located from memory, catalogs, or
   the near-miss list — precisely because the matcher struggled with them.
4. **Near misses** are the richest seam: each one is either a genuine miss
   (→ holdout per point 3) or a strong lookalike (→ hard negative per
   point 2). Triage them first.

## Expected pace

~4 s/clip on the M4 Max for short clips at frame-step 10; long files scale
roughly with duration (a 1-hour tape can take many minutes). HDD roots add
seek/read time. For a multi-thousand-file volume expect **hours**, which is
why progress is one honest line per file and Ctrl-C + rerun resumes cleanly.
Tuning: raise `--frame-step` for a faster, coarser first pass; lower
`--min-hits` (e.g. 5) to widen the candidate net at the cost of more false
confirms. The near-miss floor (hits ≥ 3) is fixed in the script
(`NEAR_MISS_MIN_HITS`).

## Notes

- Extension set and skip-directory rules mirror `scripts/VideoScan.py` and
  the app's aggressive-skip default (Finder metadata dirs, Windows trash,
  hidden dirs, iMovie cache/render folders, opaque media-library bundles).
- Duration comes from a best-effort `ffprobe` call; blank if unavailable.
- The report (CSV/HTML) is regenerated at the end of every session from the
  full JSONL — including interrupted sessions — so partial runs are usable.
