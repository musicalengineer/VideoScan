# Events: the design

**Status:** unified design, 2026-10-12. It replaces `docs/Auto_Discover_Events_in_Media.md` (Codex + Rick, 10/11) and `docs/design/events_plan_2026_10_12.md`; both are folded in here. A v0 prototype exists (`scripts/events_prototype.py`). No app code yet.

**The one question (Triage ▸ Events):** *Which recordings belong to the same family memory?*

What it should feel like: "Show me all the birthdays." "Which clips are Christmas 1998?" "Find the other recordings from this event, including the ones on another drive." "Which events are on this two-hour tape?" "Thanksgiving with Donna."

Rick's standard: the best we can do. Honest about uncertainty, local by default, and Rick's word beats every model.

---

## 1. Principles

1. **Models say *what kind* of event; capture adjacency says *which* event.** A Christmas tree proves "Christmas", not "Christmas 1998 at Ma's". Keep the two apart.
2. **Two levels:** a *category* (birthday, Christmas, Thanksgiving, vacation, wedding, …) and an *instance* (one celebration or trip). An instance may span days and places; a vacation may contain a birthday; one tape may hold several unrelated events. So: associations attach to **time ranges inside files** as well as whole files; multiple associations are allowed; parent/child is allowed; "unknown" is a valid answer.
3. **Copies are one witness.** Three copies of a tape, an A/V pair and a transcode of the master are one recording. Identity comes first.
4. **Evidence keeps its source.** Capture date, file date, transfer date, folder label and Rick's date are different things and are never blended silently. Ranges and uncertainty are kept; exact days are never invented.
5. **Suggest, then confirm.** The app proposes; Rick confirms, renames, splits, merges, dismisses. His decisions are stored apart from model output, survive rescans and model upgrades, and a dismissed suggestion does not come back on the same evidence.
6. **Nothing touches media.** Discovery never renames, moves, re-encodes or edits a file, and never alters recovered MXF pair data.
7. **Local by default.** Pixels, audio and faces of living family never leave the machine (ruling 10/10). Captions and transcripts are derived text but are *about* family; they stay local unless Rick rules otherwise.
8. **Calm UI.** Suggestions are words with a "why", not percentages, unless a number has been calibrated on Rick's own labelled footage.

## 2. Evidence we already hold (counted 10/12, 11,912 active files)

| Signal | Files | Contributes | Ambiguity |
|---|---|---|---|
| Scene captions, timestamped (Qwen2.5-VL via Dossier) | 8,323 | decorations, cakes, beaches, gatherings; in-file segment boundaries | similar scenes recur across years |
| Transcripts (Whisper) | 6,712 | "happy birthday", names, destinations, greetings, spoken dates | wrong with music, silence, tape noise |
| OCR date candidates (camcorder overlays) | 2,597 | capture dates | some entries are garbage strings; camera clocks can be wrong |
| Other on-screen text | 3,629 | signs, titles, name tags | OCR errors |
| Capture metadata: camera make/model | ~4–5k | "same camera" ⇒ same household session | copies and edits can replace dates |
| People: detected 976 · suspected 260 · **confirmed 73** | — | who was there; queries like "Donna at a birthday" | identity confidence stays separate from event confidence |
| A/V pair groups | 3,183 | one recording, not two | — |
| Footage lineage (transcode / version / same footage) | 7,621 | an edit is the same memory as its master | — |
| Full SHA-256 (Fill In Full Hashes, 10/11) | nearly all | copies collapse | — |
| Perceptual fingerprint | 2 | visual near-matches across drives | the backfill job exists but never ran; one night on the M5 |
| Dates: camera 3,585 · inferred 2,341 · folder-year 1,458 · **none 4,528** | — | sessions, instances, dating back-propagation | digitization and copying overwrite dates |
| Length: 10,874 < 5 min · 646 of 5–30 min · **355 > 30 min** | — | the 355 long tape transfers need segmentation inside the file | sparse sampling can miss short events |
| Folder and file names | all | "Christmas2010Westford", tape numbers, consecutive clip numbers (00001.MTS…) | a folder can hold mixed events or inherited wrong labels |

Thanksgiving is the stress case: a dinner table alone is weak; the word "Thanksgiving" in speech, the date, or a folder label makes it. Holiday dates guide, never dictate.

## 3. The pipeline, as layers

Each layer only reads the layers below it and writes derived, reversible data.

**0. Identity.** Collapse copies by full hash; join A/V halves; fold versions onto their master. Output: one *recording* per memory-bearing object. Unavailable volumes are deferred work; a disconnected drive never makes an association disappear.

**1. Sessions** (deterministic, no model). Group recordings by: same folder; consecutive clip numbers; same camera; capture times within a gap (start at 3 h; tune on Rick's marks). Undated recordings join a session only by folder + numbering. Sessions are the atoms everything else labels. High precision is the point; recall comes from the layers above.

**2. Segments** (long files only). Split a tape transfer where captions change subject, speech goes quiet or changes speakers, or an OCR date overlay changes. Each segment is then a recording with a time range. Sampling is coarse first, finer on promising intervals; every finding keeps its timestamp so Rick can jump to it. No sparse method claims completeness; the evaluation measures what it misses.

**3. Category labelling** — per session or segment, never per clip in isolation.
- *Now:* keyword rules on captions + transcripts (the v0 prototype), with negative cues ("mentions Christmas" ≠ "is Christmas").
- *Next:* **one local LLM call per session** (Hallie's existing Qwen path): it reads the captions, transcript excerpts, OCR text, folder name and known people, and returns JSON: `category, title suggestion, date clues, people named, confidence word, why`. A few hundred sessions, so it runs overnight for nothing. This is the biggest quality step for the least work, because it weighs all the evidence at once and explains itself.
- *Later:* text embeddings over captions + transcripts for "find more like this"; SigLIP 2 frame embeddings for the ~3,600 recordings with no caption; evaluate, never assume.

**4. Instances.** Merge sessions into one event when the category matches **and** at least two of: dates within a window; same folder label; same confirmed people; footage lineage across drives. A reliable date conflict (years apart) blocks the merge. Missing dates lower certainty, never exclude. **No similarity chains:** A~B and B~C does not merge A, B, C unless each pair qualifies. Recurring holidays stay separate unless the evidence says one instance. At archive scale: candidate retrieval + bounded comparisons, never all-pairs.

**5. Dating back-propagation** (Rick's job 2, the unexpected payoff). A dated member dates the undated members of its session (same day) and, more weakly, its event (a range). Holiday + folder year gives a range (Christmas + "1998" → 20–31 Dec 1998). OCR overlays feed in after a sanity filter. Written as **inferred dates with the reason shown**, through the existing date-priors path; Rick confirms. Up to 4,528 undated files stand to gain.

**6. Rick's decisions.** Confirm / rename / set date or place / split / merge / dismiss / exclude a clip / add a clip / "find more like this". Stored in their own file in App Support, keyed by content hash, so they survive rescans, path moves and model upgrades. They always win over later model output.

## 4. Background behaviour

- Explicit on/off, scope (volumes/folders), pause/resume, optional schedule. Starts as "while the app is open"; running after quit is a later decision.
- Foreground work (catalog, playback, Person Finder) has priority. Bounded decoders, batch sizes, memory, disk reads and cache growth; backpressure between stages.
- Checkpoint between bounded units; resume without duplicating associations; one bad file never stalls the queue; bounded retries with actionable failures.
- Invalidate only the derived results whose source content, model revision or settings changed. Preserve Rick's decisions.
- Progress as analyzed / pending / deferred / failed, in the MFO window like every long job. No O(records) work in view bodies.
- Model downloads and scope are visible. Embeddings from different model revisions are never compared.

## 5. The Events page (Triage ▸ Events)

- Event cards: representative thumbnail, approximate date or range with its source, participants, number of recordings and segments, strength in words.
- Open an event: its media timeline, the evidence for each member ("seen @ 1:35 — cake with candles"; "said — 'happy birthday dear Timmy'"; "folder name"), playback at the timestamp.
- Actions: confirm, rename, dismiss; accept/reject a member; split; merge; correct date, place, category, participants; add a recording; ask for more candidates; filter by category, person, date range, place, confirmation state.
- "Donna at Christmas" joins person evidence and event evidence, each inspectable on its own.
- Compare Footage lives here. Later, confirmed events feed clip extraction and compilations; discovery itself never produces edits or exports.

## 6. Data kept (needs, not a schema)

| Concept | Information |
|---|---|
| Analysis record | recording identity (content hash), model + runtime revisions, sampling policy, status, finished at |
| Observation | recording, timestamp or range, evidence type, result, provenance |
| Category | reusable label; optional user description |
| Event instance | stable id, name, categories, approximate date/place with sources, confirmation state, optional parent |
| Association | recording/range ↔ event, supporting evidence, strength word, suggested/accepted/rejected |
| Rick's correction | his values and membership decisions, keyed by content hash; overrides everything |

Persistence, dependencies, indexing and scheduling get their own implementation review. This document authorizes no new dependency, threading change, migration or log-format change on its own.

## 7. Models: where they fit, honestly

- **Local first.** Everything above runs on the M4 or the M5. 🔴 Ruling needed from Rick before any cloud step on *transcripts or captions*; pixels/audio/faces are already ruled out.
- **Hugging Face** is a model *source*, not a service: SigLIP 2 (frames), a small sentence-embedding model (text), the Whisper/Qwen revisions already in use. Record the exact revision, preprocessing, runtime and licence. A Hub listing proves nothing about Apple-silicon speed, memory or accuracy on tape footage; measure each.
- **The LLM-per-session step** is the quality lever. Its output is a suggestion with a why, never a fact; it must not invent names, dates or relationships.
- Fine-tuning only if evaluation shows a specific gap and enough labelled examples exist.
- Person-recognition improvements are a parallel track; a better event classifier is not a better identity matcher.

## 8. Measuring it

- **Labelled set:** Rick's ✓/✗ marks from the prototype page, frozen as the acceptance set. Pass bars are chosen before tuning, not after seeing which model wins.
- **Per category and per evidence type** (seen / said / both / folder). Tune and test split **by session or tape**, never by clip; keep copies and near-duplicates on the same side.
- **Counts that matter:** wrong merges (worst: a falsely merged family event costs trust), missed merges, wrong category, correction effort, and how many undated files gain a date Rick accepts.
- **Hard negatives in the set:** an ordinary dinner vs Thanksgiving; a decorated room with no celebration; a wedding cake vs a birthday cake; the hymn "Happy Birthday" on a TV.
- **Cost:** processing time per hour of video (decode vs inference), peak memory, index size, query latency.
- The five testing dimensions apply when app code starts: logic, 100k-record scale, media matrix, poisoned-state isolation, regression sensors (false merges, correction persistence, bounded queue, responsiveness).

## 9. Order of work

1. **Today:** Rick marks ~50 clips on the v0 page and exports.
2. **Rapid dev (1–2 days, Python):** identity + sessions; re-score against the marks; negative cues.
3. **Overnight:** LLM-per-session labelling through the local Hallie path; re-score.
4. **Dating back-propagation** into the date-priors path, with the WHY.
5. **Triage ▸ Events page:** mockup first, then build on the frozen data model; Compare Footage moves in.
6. **M5 experiments:** perceptual-fingerprint backfill; SigLIP 2 for uncaptioned clips (50–100 clips, ~20 searches, fixed sampling); text embeddings.
7. **People × events;** confirmed events feed compilations.
8. **Integration decision** after each step on evidence: useful discovery, manageable correction effort, acceptable cost.

## 10. Open questions for Rick (one at a time)

1. Cloud use on derived *text* (captions, transcripts): allowed for event labelling, or local only?
2. Should confirmed events also become folders or tags visible in the Catalog, or stay inside Events?
3. Which categories matter most to you beyond the holiday set — e.g. music jams, school events, first days?
