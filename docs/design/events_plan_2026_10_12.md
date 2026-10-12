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

## Design: how grouping works (v1, 10/12 afternoon)

**Principle.** Models tell us *what kind* of event a clip shows. Capture adjacency tells us *which* event it is. Keep the two apart, and let Rick's confirmations outrank both.

### Evidence we already hold (counted 10/12)

| Signal | Files | Use |
|---|---|---|
| Scene captions (Qwen2.5-VL, timestamped) | 8,323 | category; in-file segments |
| Transcripts (Whisper) | 6,712 | category; names, places, spoken dates |
| OCR date candidates (camcorder overlays) | 2,597 | dating (noisy: some are garbage strings; needs a sanity filter) |
| Other on-screen text | 3,629 | signs, titles, names |
| Camera make/model | ~4–5k | "same camera" = same household session |
| People: detected 976 · suspected 260 · confirmed 73 | — | who was there; `confirmedByUserPeople` is fact, the rest is a hint |
| A/V pair groups | 3,183 | one recording, not two |
| Footage lineage (transcode / version) | 7,621 | an edit is the same memory as its master |
| Full SHA-256 | nearly all | copies are one witness |
| Perceptual fingerprint | 2 | job exists but never ran; worth one night on the M5 for visual near-matches |
| Length | 10,874 under 5 min · 646 of 5–30 min · 355 over 30 min | the 355 long tape transfers need segmentation inside the file |

### Layers

0. **Identity.** Collapse copies (full hash), join A/V halves, fold versions onto their master (`footage`). Output: one *recording* per memory-bearing object.
1. **Sessions.** Group recordings deterministically: same folder, consecutive clip numbers (00001.MTS…), same camera, capture times within a gap (start at 3 h). High precision, no model. Sessions are the atoms everything else labels. Undated recordings join a session only by folder + numbering.
2. **Segments** (long files only). Split a tape transfer where captions change subject, speech goes quiet, or an OCR date overlay changes. Each segment is then treated like a recording.
3. **Category labelling.** Per session or segment, not per clip:
   - **now:** keyword rules on captions + transcript (the v0 prototype), with negative cues;
   - **next:** one local LLM call per session (Hallie's Qwen path) that reads the captions, transcript excerpts and folder name and returns JSON: `category, title suggestion, date clues, people named, confidence, why`. A few hundred sessions, so it is cheap and runs overnight;
   - **later:** text embeddings over captions + transcripts for "find more like this"; SigLIP frames for the ~3,600 recordings with no caption.
4. **Instances.** Merge sessions into one event when category matches **and** two of: dates within a window, same folder label, same confirmed people, footage lineage across drives. A reliable date conflict (years apart) blocks the merge. No similarity chains: A~B and B~C does not merge A, B, C unless each pair qualifies.
5. **Dating back-propagation.** A dated member dates the undated members of its session (same day) and, more weakly, its event (the range). Holiday categories plus a folder year give a range (Christmas + "1998" → 20–31 Dec 1998). Written as inferred dates with the reason shown; Rick confirms.
6. **Rick's decisions.** Confirm / rename / split / merge / dismiss / exclude a clip. Stored in their own file in App Support, keyed by content hash, so they survive rescans, model upgrades and path moves. A dismissed suggestion does not return on the same evidence.

### Where models fit, honestly

- **Local first.** Everything above runs on this Mac or the M5. Captions and transcripts are derived text, but they are *about* living family; keep them local unless Rick rules otherwise. 🔴 Ruling needed before any cloud step on transcripts.
- **Hugging Face** is a model source, not a service: SigLIP 2 (frames), a small sentence-embedding model (text), and whatever Whisper/Qwen revisions we already use. Record the exact revision.
- **The LLM-per-session step is the big quality jump for the least work**, because it reads all the evidence at once and explains itself. Its output is a suggestion with a why, never a fact.

### Measuring it

- Rick's ✓/✗ marks from the prototype page are the first labelled set. Freeze them as the acceptance set; pick pass bars before tuning.
- Report per category and per evidence type (seen / said / both / folder). Split by session or tape when tuning, never by clip.
- Count: wrong merges (worst), missed merges, wrong category, and how many of the 4,528 undated files gain a date Rick accepts.

### Order of work

1. Rick marks ~50 clips on the v0 page (today).
2. Sessions + identity layer in Python; re-score (rapid dev, 1–2 days).
3. LLM-per-session labelling via the local Hallie path, overnight; re-score.
4. Dating back-propagation into the date-priors path, with the WHY (job 2 payoff).
5. Triage ▸ Events page: mockup, then build on the frozen data model.
6. SigLIP on the M5 for uncaptioned clips; people × events.
