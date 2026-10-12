# Events: plan (start small, iterate)

**Status:** v0 prototype is running. This plan goes step by step from there. Inputs:
- `docs/Auto_Discover_Events_in_Media.md` (Codex + Rick, 10/11)
- the tab charter for Triage ▸ Events.

**The one question:** *Which recordings belong to the same family memory?*

## What we already have, and didn't know (10/12)

- **Evidence is already in the catalog.** Of 11,914 active files:
  - 8,143 have Dossier scene descriptions (Qwen2.5-VL).
  - 6,230 have Whisper transcripts.
  - Dates come from the camera (3,585), from inference (2,341) and from folder names (1,458). 4,528 have no date.
- **Copies collapse by full SHA-256**, from Fill In Full Hashes on 10/11. Three copies of one tape count as one witness.
- **v0 prototype:** `scripts/events_prototype.py` builds a local page at `~/Library/Application Support/VideoScan/events-prototype/index.html`.
  - First run: 1,274 unique clips with event evidence became 308 candidate events, 109 of them strong. 1,079 clips have a preview frame.
  - The page shows event cards with thumbnails and the evidence for each clip (seen at a timestamp, or said). Rick marks each clip ✓/✗; the marks stay in his browser and can be exported.
  - **It stays local.** It is never published: family pixels and speech don't leave the machine.

## Steps

**Step 0 (today): look and mark.** Rick opens the page and marks about 30–50 clips across Birthday, Christmas and Thanksgiving, plus whatever catches his eye, then clicks Export. 15 minutes.

**Step 1: measure, then tune (rapid, Python only).**
- Score how often a mark is right, per category and per evidence type (seen / said / both / folder name).
- Expected false alarms, all cheap to fix with rules:
  - speech that only *mentions* Christmas;
  - "ocean" in a painting;
  - the hymn "Happy Birthday" on TV.
- Add negative cues, and require "both", or "said ≥ 2×", for the weak categories.
- Re-run, re-mark, and stop when precision is good enough for suggestions. A target is set from the first scores, before tuning.

**Step 2: events help *dating*, which is Rick's job 2.** This is the payoff we didn't expect.
- A dated clip can date its undated siblings in the same event.
- A Christmas event in a folder that says 1998 gives a date range around 25 Dec 1998.
- These become **inferred dates with a stated reason**, using the existing date-priors design ("show the WHY"). They go into the date inference as suggestions, never as facts.
- Up to 4,528 undated files stand to gain.

**Step 3: the Triage ▸ Events page in the app.**
- Event cards with the same evidence as the prototype.
- Actions: Confirm, Rename, Split, Merge, Dismiss, and add or remove a clip.
- Rick's decisions are stored separately and always win. A rejected suggestion never comes back on the same evidence.
- Compare Footage lives here.
- Design with a mockup first. No O(records) work in views.

**Step 4: see what the descriptions missed (M5).**
- SigLIP 2 frame embeddings for the roughly 3,800 clips with no scene description, plus free-text scene search ("cake with candles").
- An isolated Python environment on the M5, measured against Rick's marks from step 0 before it goes into the app.

**Step 5: people × events.** "Donna at Christmas" joins Person Finder hits with event membership, keeping each kind of uncertainty visible on its own.

## Rules (from the Codex doc, kept)

- Two levels: a *category* (Christmas) and an *instance* (Christmas 1998 at Ma's). A tree proves the first, not the second.
- An event can be a time range inside a long tape.
- Evidence keeps its source. Capture date, file date and Rick's date are never confused.
- The app suggests and Rick confirms. Everything is reversible, and source media is never touched.
- Local inference only (Hallie cloud ruling, 10/10).
