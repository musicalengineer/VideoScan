# Morning Briefing — 2026-04-23

Written 2026-04-23 03:00 UTC (≈10 PM Middlefield). Target: Rick, first-thing-in-the-morning ~11 AM.

## Overnight status — green

| | |
|---|---|
| Tests | **201 passed, 0 failed** (Swift Testing + XCTest + UI, `/tmp/vs_overnight.xcresult`) |
| Overall coverage | **18.97%** (6628 / 34937) — up from 6.69% baseline |
| Logic-only coverage | **24.88%** (4428 / 17800) — up from 17.5% baseline |
| Build | Release build green, launchable from DerivedData |
| Open GitHub issues | 24 (ref `gh issue list`) |
| Branch / SHA | `main` / `16116a54` |

Metrics row appended below; full history will be on the `metrics` branch when CI next runs.

## Fresh metrics JSON

```
{"ts":"2026-04-23T02:55:56Z","sha":"16116a54","coverage_overall_pct":18.97,
 "coverage_logic_pct":24.88,"logic_lines":17800,"logic_covered":4428,
 "swiftlint_warnings":916,"swiftlint_errors":368,"periphery_findings":122,
 "total_swift_lines":25844,"files_over_1000":7,
 "worst_file":"VideoScanTests.swift:2887","test_count":197}
```

### What's up with SwiftLint (916 / 368 vs ~89 baseline)

Not a code-quality cliff — the rule set expanded. Breakdown of the top violations:

| Count | Rule | Severity |
|---|---|---|
| 479 | `identifier_name` | Cosmetic — short vars like `fm`, `mb`, `gb`, `r`. Many are idiomatic. |
| 333 | `comma` | Trailing-comma style. |
| 139 | `line_length` | Mostly > 120 chars. |
| 48 | `opening_brace` | Brace-placement style. |
| 36 | `function_body_length` | Real signal — large functions. |
| 33 | `cyclomatic_complexity` | Real signal — branchy functions. |
| 17 | `file_length`, `type_body_length` | Two of the 2000+ line files you already know about. |

Signal-to-noise: the real refactor signal is in the last ~90 warnings (body length + complexity + file length). The other ~820 are style nits worth silencing or batch-fixing.

### Periphery (122 findings)

Mostly expected: `AvbParser.swift` has many `Assign-only property` warnings — those are wire-format struct fields populated during parse but not read yet. Plus `ArcFaceEngine.reset()` unused, a couple of orphaned inspector helpers, `bufferedCopy` unused. No smoking guns; this is a clean-up-when-bored list.

### File size leaders (7 over 1000 lines)

1. `VideoScanTests.swift` — 2887 (test file, fine)
2. `VideoScanModel.swift` — 2863 (real target)
3. `PersonFinderModel.swift` — 2699 (real target)
4. `CatalogHelpers.swift` — 1445
5. `PersonFinderView.swift` — 1133
6. `ContentView.swift` — 1115
7. `ScanJobRow.swift` — 908 (borderline)

VideoScanModel + PersonFinderModel are still the two god objects that matter most. You've been chipping at them; keep chipping.

---

## Face detection — the North Star, as I think about it

Per your message last night: **identifying family across decades of video so we can archive them properly** is the whole point. Everything else is in service of this. A few thoughts while you slept.

### The hard core of the problem, in one sentence

Generic face embedding models treat Donna@22 and Donna@55 as different people, and they treat Tim and Dan as the same person. We need the opposite.

### The existing docs already cover most of the theory

We have three thorough design docs:
- `docs/issue-02-face-detection-accuracy.md` — adaptive threshold / temporal / preprocessing / ensemble
- `docs/issue-06-custom-face-model.md` — ArcFace fine-tune vs few-shot vs SVM-on-Vision
- `docs/catalog-aided-face-detection.md` — pre-filter, negative cache, folder priors, format fingerprints

What's **missing from all three**: we can't measure whether any change helps because **we don't have a labeled ground truth**.

### The one thing to do tomorrow (or this week): build a tiny truth set

Before any algorithm work, 1-2 hours of this unlocks everything:

1. Pick **5 short clips** (30 s – 2 min each) where you already know exactly who is in frame and roughly when. Mix eras: one 1990s VHS, one 2000s DV, one 2010s HD, one 2020s HEVC, one mixed.
2. Store the ground truth as JSON alongside each clip:
   ```json
   {
     "clip": "tests/fixtures/truth/donna_1995_bday.mp4",
     "appearances": [
       { "person": "donna", "start": 3.0, "end": 12.5 },
       { "person": "donna", "start": 18.2, "end": 25.0 },
       { "person": "dan",   "start": 6.0, "end": 8.5 }
     ]
   }
   ```
3. Add a `PersonFinderGroundTruthTests.swift` that runs the current engine against these clips and reports precision / recall per person.

**Why this is the right first step:** every FD idea in the existing docs is speculative until we can show it moved a number. The truth set is the scoreboard. Without it, every engine tweak is a vibe check and we drift.

Cost: half a day including video clip selection. Payoff: every subsequent FD change is now scored automatically.

### The second thing — per-age anchors

Once the truth set exists, the cheapest meaningful accuracy experiment:

In `POIProfile`, store multiple reference photos **with era tags**:

```swift
struct PoiReferencePhoto {
    let imagePath: String
    let eraStart: Int?   // e.g. 1995
    let eraEnd: Int?     // e.g. 2000
    let ageApproximate: Int?  // optional — "Donna at 22"
}
```

At match time, restrict the candidate references to those whose era overlaps the video's inferred date (from catalog year column / path tokens). Donna@1995 only gets compared against Donna@1993-1998 references. That removes the "Donna@22 doesn't look like Donna@55" false negative without changing any ML.

This is the tiny, concrete first step toward the "this is Donna at 18" vision you described. It doesn't train a model — it just stops comparing across unreasonable age gaps. Zero new dependencies.

Expected lift: modest on recent footage, substantial on 80s/90s material. Worth measuring against the truth set.

### The third thing — the negative cache

`docs/catalog-aided-face-detection.md` idea #2 is the single highest-leverage **pipeline** change. Not FD research, but it changes the rhythm of the whole project: second-scan of the same archive becomes mostly cache hits, freeing compute to re-scan the *interesting* (positive-hit) material with better engines. Schema already sketched in that doc. Maybe a day of work.

I'd sequence it as: truth set → per-age anchors → negative cache → then consider training.

### Training a family-specific model — the long arc

Your north-star vision (train a family model, query it with "this is Donna at 18") is the right destination, but it sits past a prerequisite: **labeled training data**. Every training approach in `issue-06-custom-face-model.md` needs 20-50 images per person, ideally with age labels. Today we have reference photos but no era tags and no corrections.

A concrete bootstrapping path:
1. Truth set exists (step 1 above) → we can measure baseline accuracy.
2. Run current engines against everything, save all *candidate* faces with their (source file, timestamp, confidence).
3. Build a minimal **correction UI** — "is this Donna? Y / N / actually X". Each correction becomes a labeled sample.
4. After a few thousand corrections, train Option C from issue-06 (SVM on Vision embeddings). Measure lift.
5. If Option C yields ≥10% recall gain, invest in Option A (fine-tuned ArcFace on same dataset).

The labels-from-corrections flywheel is what makes this work for a one-family archive. It's a different shape than "download CelebA, train model" — it's built on your own curation time converting into model quality.

### What the plugin architecture buys us

`project_pluggable_face_detect.md` memo says four engines exist: Vision / ArcFace / dlib / Hybrid. The right use of that plumbing once the truth set is built is **A/B on the scoreboard**. Same clips, four engines, four precision/recall numbers. Then we know which engine we should be investing in, rather than running all four on the off chance.

---

## Squirrel watch

Bugs / features that are tempting but **not on the FD critical path**:

- **#3 dlib RT FD window empty** — high-priority bug, but dlib is only one of four engines and the least strategic. Fix if it blocks measurements; otherwise defer.
- **#4 Hybrid FD mode doesn't work** — same. Fix after truth set so we can confirm Hybrid actually beats single-engine.
- **#21 Tear-off Media/People** — pure UX polish.
- **#24 1-2 min Import from Photos during search** — real UX friction but tangential.
- **#36 RT Scan window auto-clear** — minor UX.
- **#32 Recover broken videos** — interesting but a different pipeline.
- **#33 Expand Copy/Duplicate options** — the Compare & Rescue work we did yesterday already moves the ball. Next bite would be "volume groups" so you don't re-check MacPro volumes each session.

If you want to spend the morning on small wins, #36 and #21 are cheap and visible. But the **one investment with the biggest long-term return** is the truth set — it converts every future FD experiment from guesswork to measurement.

---

## The short version

1. **Green across the board overnight.** Tests / coverage / build all healthy.
2. **SwiftLint regression is mostly cosmetic.** Real refactor signal is ~90 warnings, not 1284.
3. **FD North Star needs a scoreboard before a strategy.** Build the labeled truth set this week. Everything downstream multiplies in value once it exists.
4. **Per-age anchors is the cheapest accuracy experiment** and the first concrete step toward the "Donna at 18" custom-model vision.
5. **Negative cache is the cheapest pipeline win** and should come before training.

Coffee's on you. Welcome back.

— Claude (Opus 4.6)
