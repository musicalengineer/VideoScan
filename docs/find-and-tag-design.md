# Find & Tag — auto-tagging mechanism (v1, 2026-08-02)

The app mechanism that runs a per-person recipe (docs/donna-recipe-v1.md)
and writes machine-tier person tags. FOR CODEX: testing pointers at bottom.

## Two doors, one engine

1. Catalog right-click → **Find & Tag → <person>** — runs over the SELECTION.
2. People → <POI> → **Search Catalog…** — same job, all records
   (GATED: ships only after grading gates G2/G3 pass; selections-only until).

Both create a `FindPersonJob` (new MFO verb, badge "Find") in the Media File
Operations window — standard lifecycle: progress, Cancel, Pause (SIGSTOP of
the python child), stall watchdog fed by heartbeats.

## Tag tiers and notation (NO new tag type)

| Display | Storage | Meaning |
|---|---|---|
| Donna | confirmedByUserPeople | Rick said so (ground truth) |
| Donna* | detectedPeople | recipe confident (score ≥ 0.55) |
| Donna? | suspectedPeople | recipe thinks maybe (0.38 ≤ score < 0.55) |

Below 0.38: no tag. Confirming a `Donna*` promotes to plain `Donna` (existing
People menu). Un-tagging writes a rejection; **the job skips records whose
rejectedPeople contains the person** (veto rule) and skips already-confirmed
records (nothing to add). Provenance: a File-Journey-style stamp appended to
the machine `notes` field: `FindPerson(Donna) v1 <ISO>: score 0.71 → Donna*`.

## v1 engine: python bridge (Swift-native port in progress on a subagent)

`FindPersonJob` shells out ONCE per job via ProcessRunner to
`tools/donna-recipe/find_person_batch.py` (venv python3.12), passing
`--gallery tests/fixtures/photos/Donna --clips-file <tmp>` where the tmp file
lists selected record paths one per line. Streamed stdout protocol (JSONL):

    {"event":"ready","clips":N}            after model prep (~15 s)
    {"event":"beat","path":P,"frame":K}    heartbeat every ~50 frames → watchdog tick
    {"event":"result","path":P,"score":S,"frames":F,"faces":G}
    {"event":"result","path":P,"error":"..."}

Per-clip errors are data (job continues); nonzero exit = setup failure.
Scoring internals = tools/donna-recipe/recipe_smoke.py (SCRFD-10G → two-tier
size gates → sex gate → ArcFace vs era-banded centroids → top-5 mean),
validated at AUC 0.995 on DonnaTestVideos (docs/donna-recipe-smoke-2026-08-01.md).

Native port plan: same job, `RecipeScoring` seam — python bridge and Swift
engine (existing AdaFace/ArcFace CoreML path + converted genderage) selectable;
thresholds recalibrate per embedding space (they are NOT portable across
engines).

## Known v1 constraints (deliberate)

- Donna is the only tuned recipe; other POIs will appear as "generic" later.
- Gallery path + venv python path are constants for Rick's machine.
- Sex gate is per-face; per-track majority voting comes with the tracker.
- Thresholds 0.55/0.38 are smoke-derived; C2-style calibration lands with G2.

## For codex — testing this

Python tier (now): exercise `find_person_batch.py` directly — protocol shape
(ready/beat/result lines), per-clip error isolation, missing files, empty
clips-file, gallery-with-no-centroids exit, threshold boundary clips from
DonnaTestVideos. `recipe_smoke.py` is the reference scorer; scores must agree.
Swift tier (when job lands): JSONL line parser is a pure nonisolated func on
FindPersonJob; tag application goes through `applyRecipeVerdict` on
VideoScanModel (veto/skip/promote rules above) — both unit-testable without
python. Job lifecycle (cancel/pause/stall) follows VerifyAudioJob patterns.
