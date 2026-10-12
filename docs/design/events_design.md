# Events: the design

**Status:** unified design **v2**, 2026-10-12. v1 folded the 10/11 Auto-Discover Events doc (Codex + Rick; removed 10/12, in git history) (Codex + Rick, 10/11) and the Manager's layered plan into one document. v2 takes in codex's highest-reasoning design talk (`docs/reviews/codex/codex-design-events-2026-10-12.md`, verdict "fix", 8 findings, all accepted). A v0 prototype exists (`scripts/events_prototype.py`). No app code yet.

**The one question (Triage ▸ Events):** *Which recordings belong to the same family memory?*

What it should feel like: "Show me all the birthdays." "Which clips are Christmas 1998?" "Find the other recordings from this event, including the ones on another drive." "Which events are on this two-hour tape?" "Thanksgiving with Donna."

Rick's standard: the best we can do. Honest about uncertainty, local by default, and Rick's word beats every model.

**Codex's one-line verdict on v1, which v2 is built around:** *the central mistake is turning useful clues into authoritative structure too early.* Versions are not one recording, sessions are not atoms, and membership is not permission to inherit a date. Carry the uncertainty through every step; let Rick collapse it.

---

## 1. Principles

1. **Models say *what kind* of event; capture adjacency says *which* event.** A Christmas tree proves "Christmas", not "Christmas 1998 at Ma's". Keep the two apart.
2. **Two levels:** a *category* (birthday, Christmas, Thanksgiving, vacation, wedding, music, …) and an *instance* (one celebration or trip). An instance may span days and places; a vacation may contain a birthday; one tape may hold several unrelated events. So: associations attach to **ranges inside files** as well as whole files; multiple associations are allowed; parent/child is allowed; "mixed" and "unknown" are valid answers.
3. **Three things that are never confused:** *identical recording* (byte-identical copies; a verified A/V pair), *contains some of the same footage* (a transcode, an edit, a compilation, another camera at the same party) and *event membership*. Copies are one witness. Lineage is a typed relationship with a range where known. Membership never proves footage is "covered" or safe to remove.
4. **Evidence keeps its source.** Capture date, file date, transfer date, folder label, OCR overlay and Rick's date are different things and are never blended silently. Ranges and uncertainty are kept; exact days are never invented. **Event duration** ("a week in Maine") is not **date uncertainty** ("sometime in 1998").
5. **Suggest, then confirm.** The app proposes; Rick confirms, renames, splits, merges, dismisses, adjusts a range. His decisions are stored apart from model output, survive rescans and model upgrades, and a dismissed suggestion does not come back on the same evidence.
6. **No circular corroboration.** A date derived from an event never counts as support for the membership that produced it. Rejecting an anchor invalidates its unconfirmed descendants.
7. **Nothing touches media.** Discovery never renames, moves, re-encodes or edits a file, and never alters recovered MXF pair data.
8. **Local by default.** Pixels, audio and faces of living family never leave the machine (ruling 10/10). Captions and transcripts are derived text but are *about* family; they stay local unless Rick rules otherwise. v1 needs no cloud.
9. **Calm UI, honest words.** "Caption suggests birthday" rather than "seen: birthday". Confidence words come from evaluated evidence rules, never from a model's self-assessment. No percentages without calibration on Rick's own footage.
10. **Rick's attention is the scarce resource.** Local compute is not. Spend compute to ask him fewer, better questions.

## 2. Evidence we already hold (counted 10/12, 11,912 active files)

| Signal | Files | Contributes | Ambiguity |
|---|---|---|---|
| Scene captions, timestamped (Qwen2.5-VL via Dossier) | 8,323 | decorations, cakes, beaches, gatherings; in-file boundaries | similar scenes recur across years; a caption is a model's guess |
| Transcripts (Whisper) | 6,712 | "happy birthday", names, destinations, greetings, spoken dates and ages | wrong with music, silence, tape noise; a TV can say "happy birthday" |
| OCR date candidates (camcorder overlays) | 2,597 | what the camera clock *displayed* | some entries are garbage strings; a reset clock reads "Jan 1998" for years |
| Other on-screen text | 3,629 | signs, titles, name tags | OCR errors |
| Capture metadata: camera make/model | ~4–5k | supporting evidence of the same household session | not device identity; copies and edits can replace dates |
| People: detected 976 · suspected 260 · **confirmed 73** | — | who was there; "Donna at a birthday" | only 73 confirmed hits: cannot carry recall archive-wide; identity confidence stays separate |
| A/V pair groups | 3,183 | one recording, not two | — |
| Footage lineage (transcode / version / same footage) | 7,621 | typed relationships; a compilation points at several sources | lineage ≠ identical; ranges mostly unknown today |
| Full SHA-256 (Fill In Full Hashes, 10/11) | nearly all | byte-identical copies collapse | — |
| Perceptual fingerprint | 2 | visual near-matches across drives | backfill job exists, never ran; one night on the M5, *after* the review loop proves value |
| Dates: camera 3,585 · inferred 2,341 · folder-year 1,458 · **none 4,528** | — | adjacency, instances, derived-date suggestions | digitization and copying overwrite dates; a transfer date is not a capture date |
| Length: 10,874 < 5 min · 646 of 5–30 min · **355 > 30 min** | — | the 355 long transfers hold several events each | sparse sampling misses short events |
| Folder and file names; **every copy's location** | all | "Christmas2010Westford", tape numbers, consecutive clip numbers; two folders for one copy are two labels about one witness | a folder can be thematic ("Donna birthdays"), mixed, or inherit a wrong label |
| Human organization already made | Avid bins, FCP projects, tape labels, sidecars | intentional groupings; sequence placement is evidence | a highlight reel still needs range-level reading |

Thanksgiving is the stress case: a dinner table alone is weak; the word "Thanksgiving" in speech, the date, or a folder label makes it. Holiday dates guide, never dictate.

## 3. The pipeline (reordered per codex)

Each stage writes derived, reversible suggestions. Rick's decisions constrain every stage. Nothing downstream is "settled truth".

**A. Identity + sourced observations.**
- Collapse byte-identical copies (full hash); keep verified A/V pairing. Everything else in `footage` stays a *typed relationship* (transcode-of, excerpt-of, same-footage-as) with a range mapping where known. A compilation is its own recording with several source relationships.
- Gather every observation with its source id, timestamp or range, type and provenance — including **original date observations before any grouping** and the labels from *every copy's location*.
- Unavailable volumes are deferred work; a disconnected drive never makes an association disappear.

**B. Provisional ranges and capture runs.**
- The smallest addressable unit is a **recording range**, defaulting to the whole file.
- *Capture runs* are reversible adjacency suggestions over ranges: trusted capture continuity (camera clock, consecutive numbering within one card dump) gives strong adjacency; folder + numbering alone gives only a candidate neighbourhood; camera make/model is supporting. Bound the adjacent gap **and** the total span, so three-hour gaps cannot chain a week together. Allow "mixed" and splitting even for short edited files.
- Long transfers (and any file whose evidence disagrees with itself) get candidate boundaries where captions change subject, speech goes quiet or changes speakers, or an OCR overlay changes. Boundaries are suggestions with timestamps; Rick can move them. Segmentation and adjacency refine each other; neither is final.

**C. Category suggestions** — per range or run, never per clip in isolation.
- *Now:* keyword rules on captions + transcripts with negative cues ("mentions Christmas" ≠ "is Christmas"; "Happy Birthday" from a TV).
- *Next:* **one local LLM call per run, as an evidence adjudicator, not a storyteller.** It receives a bounded, chronological **evidence packet**: observation ids, timestamps, source types, surrounding context, contradictory observations, explicit coverage gaps, and *neutral samples*, not only keyword hits. It returns: possible categories (plural) with supporting and refuting observation ids; literal name and date **mentions** (distinct from "person present"); `mixed` / `insufficient evidence` when warranted; unknown fields **null**. Citations are validated against the packet; names and dates must appear in the evidence or are dropped. Titles are generated from validated fields. Confidence words come from evidence rules, not from the model.
- Model size is an experiment: Qwen2.5-VL-3B (4-bit) is the baseline; a larger local text model on the M5 is compared on identical packets and held-out cases, chosen by errors and cost. A bigger model cannot recover a detail the captions never had; targeted local re-inspection (re-caption or re-transcribe a disputed range) may help more. The run count is unproven — conservative grouping may leave thousands — so packet size is bounded and throughput measured.
- *Later, on evidence:* text embeddings for "find more like this"; SigLIP 2 frames for uncaptioned recordings.

**D. Instance suggestions.**
- Category *compatibility* drives retrieval; category equality is **not** required (candles indoors and children outside can be one party).
- A proposed member attaches to an **anchor** (an established event) only with specific support: verified matching footage at the relevant ranges; Rick's explicit membership; or corroboration specific to *that occasion*. Repeated family members and generic folders are weak support. A folder-derived date and that folder's label are **one** source, not two.
- Whole-group contradiction check: a reliable date conflict (years apart), or two distinct dated celebrations under one thematic folder, blocks the merge. Proposed members never become new authorities merely by joining. No uncontrolled chains, but a weeklong trip is one event: direct support to the anchor, not pairwise evidence between every two members.
- Anything short of that stays a *proposed link* for review.

**E. Derived-date suggestions** (Rick's job 2) — **after** membership review, never before.
- Provenance firewall: original date observations are preserved separately; event-derived dates never corroborate the memberships that produced them; dependencies are tracked so a rejected anchor withdraws its unconfirmed descendants.
- Clock credibility: repeated OCR readings establish what the overlay *said*; plausible calendar values and chronological consistency are checks; only independent corroboration or Rick establishes that the clock was right.
- Holiday + folder year does **not** become "20–31 December": decorating, concerts and delayed celebrations fall outside it. Keep the year and the Christmas association as two separate facts.
- Words: "directly supported", "inferred from event", "conflicting"; confirmation separate. v1 shows a **date preview** and requires acceptance through the existing date action. Nothing is written automatically.

**F. Rick's decisions.**
- Confirm / rename / set date or place / split / merge / dismiss / accept or reject a member / adjust a range / "these are different occasions" / add a recording / "find more like this".
- Stored in their own file in App Support with **durable event identities**, source-content ranges (content hash + range), and explicit membership and merge decisions. "Different occasions" survives independently of any generated grouping id. Rejecting a *category* is distinct from rejecting an *instance membership*.
- A rerun reconciles with these constraints. A genuinely new observation may offer reconsideration; a differently worded model answer does not. Automatic transfer of corrections across edited versions waits for reliable range mappings; the limit is shown, not hidden.

## 4. Background behaviour

- Explicit on/off, scope (volumes/folders), pause/resume, optional schedule. Starts as "while the app is open"; after-quit is a later decision.
- Foreground work has priority. Bounded decoders, batch sizes, memory, disk reads, cache growth; backpressure between stages.
- Checkpoint between bounded units; resume without duplicate associations; one bad file never stalls the queue; bounded retries with actionable failures.
- Invalidate only derived results whose source content, model revision or settings changed. Preserve Rick's decisions.
- Progress as analyzed / pending / deferred / failed, in the MFO window like every long job. No O(records) work in view bodies.
- Model downloads and scope are visible. Embeddings from different model revisions are never compared.

## 5. The Events page (Triage ▸ Events)

**The smallest honest v1 is a useful review queue with persistent results**, not a wall of named cards.

- A few useful categories to start, including **Music / performance** (Rick's own recordings; casual playing, rehearsals, jams, recitals and recorded music kept apart when evidence allows), conservative whole-file groups, and timestamped candidate ranges for mixed tapes.
- Each card: representative thumbnail, date or range *with its source*, participants (confirmed vs suggested), number of recordings and ranges, strength in words.
- Open an event: its media timeline; for each member the evidence ("caption @ 1:35 suggests cake with candles"; "transcript: 'happy birthday dear Timmy'"; "folder label"), playback at the timestamp.
- Actions: accept/reject membership, rename, split, merge, manual range adjustment, "different occasions", correct date/place/category/participants, add a recording, ask for more candidates. Filters by category, person, date range, place, confirmation state.
- **High-value questions:** when one answer resolves a whole ambiguous group, ask it — "Same birthday, or different years?" beside two representative moments.
- Uncertain cross-run links remain suggestions. Confirmed events stay browsable after their review task is done.
- Compare Footage and master selection connect here (tab charter). Grouping alone never marks a clip covered.
- Deferred until the review loop proves value: automatic dating, event hierarchies, exhaustive segmentation, new embedding backfills, compilations from events.

## 6. Data kept (needs, not a schema)

| Concept | Information |
|---|---|
| Recording | content hash; verified pair; typed lineage relationships with ranges where known |
| Observation | recording + range, evidence type, result, source id, provenance (original dates kept pre-grouping) |
| Capture run | member ranges, adjacency basis, span; reversible |
| Category | reusable label; optional user description |
| Event instance | **durable id**, name, categories, date/place with sources and words, confirmation state, optional parent |
| Association | range ↔ event, supporting/refuting observation ids, strength word, suggested / accepted / rejected |
| Derived date | value or range, dependencies (which anchors), word, accepted or not |
| Rick's decision | membership, merge, "different occasions", range edits, category rejections; keyed by durable event id + content range; overrides everything |
| Analysis record | recording, model + runtime revisions, sampling policy, status, finished at |

Persistence, dependencies, indexing and scheduling get their own implementation review. This document authorizes no new dependency, threading change, migration or log-format change on its own.

## 7. Models: where they fit, honestly

- **Local first.** Everything above runs on the M4 or the M5. v1 needs no cloud. 🔴 Ruling still wanted from Rick on cloud use for *derived text*, for later steps.
- **Hugging Face** is a model *source*, not a service: SigLIP 2 (frames), a small sentence-embedding model (text), the Whisper/Qwen revisions already in use. Record exact revision, preprocessing, runtime and licence. Measure Apple-silicon speed, memory and accuracy on tape footage; a Hub listing proves none of it.
- **The LLM is an adjudicator.** It weighs cited evidence and says "insufficient" when that is the truth. It never invents names, dates or relationships; validation enforces that.
- **Resample where evidence disagrees** before upgrading models wholesale: spend local vision/audio work around suspected boundaries, conflicting dates and weak candidates.
- Fine-tuning only if evaluation shows a specific gap and enough labelled examples exist.
- Person-recognition improvements are a parallel track; a better event classifier is not a better identity matcher.

## 8. Measuring it

**Two sets, never one.**
- **Development set:** Rick's ✓/✗ marks on the v0 prototype page (category + content only). Good for discovery and tuning; **not** an acceptance set — fifty correlated clip marks cannot speak for grouping, and zero errors in fifty independent trials still allows roughly a 6% error rate.
- **Acceptance (challenge) set**, frozen before tuning, split **by occasion/tape** with all copies, edits and camera views of an occasion on the same side: category judgments; same-occasion / different-occasion pairs; whole-group judgments; date judgments; recurring holidays across years; two celebrations close together; themed folders; transfers; compilations; ordinary gatherings; TV and music mentions; **unretrieved footage** to expose misses; fully annotated mixed tapes for segmentation recall.

**Pilot gates (codex's, adopted; fixed before tuning; coverage frozen so abstention cannot manufacture a win):**

| Step | Single gating metric |
|---|---|
| Identity | False equivalences: zero |
| Capture runs | Contaminated runs in the challenge set: zero |
| Segmentation | Distinct-event recall on annotated tapes: ≥ 90% |
| Category | Precision at fixed suggestion coverage: ≥ 90% |
| Instances | Falsely combined occasions in the challenge set: zero |
| Dating | Incorrect or unjustifiably precise suggestions: zero |
| Decisions | Lost or overridden decisions after reruns: zero |
| Page usefulness | Correct events found per Rick-minute: better than v0 |

These are launch criteria for *reviewed suggestions*, not claims of archive-wide reliability. Also tracked: wrong merges (worst), missed merges, correction effort, processing time per hour of video (decode vs inference), memory, index size, query latency. The five testing dimensions apply once app code starts.

## 9. Ideas ranked by value ÷ effort (codex + Manager)

1. **Ask high-value questions** that resolve whole groups (v1 page).
2. **Recover existing human organization:** labels from every copy; Avid bins (we already parse `.avb`), FCP projects, tape labels, sidecars.
3. **Rare-phrase and matching-audio search:** find the other camera angle or an excerpt's source tape; treat quoted/reused audio with care.
4. **Resample where evidence disagrees** (targeted re-caption / re-transcribe) before blanket model upgrades.
5. **Confirmed recurring locations:** Rick labels a few "Ma's living room" examples; retrieval and context, not occasion identity.
6. **Music as an explicit activity family.**
7. **Birthday + spoken age** → a candidate year (a face near a cake does not say whose birthday; a birth date does not say when it was celebrated).
8. **Diarization, then optional voice identification,** behind the cheaper gains.

## 10. Order of work

1. **Today:** Rick marks ~50 clips on the v0 page and exports (development set).
2. **Rapid dev (Python):** identity with typed lineage; sourced observations incl. original dates; capture runs with span bounds; re-score. Build the first challenge set *with* Rick (same-occasion pairs, hard negatives).
3. **Overnight:** evidence packets + LLM adjudication on the local Hallie path; citation validation; re-score against the challenge set.
4. **Triage ▸ Events v1:** mockup, then the review queue with durable decisions and high-value questions. Compare Footage connects.
5. **Derived-date previews** through the existing date action, after membership review works.
6. **M5 experiments on evidence:** resample-on-disagreement; perceptual-fingerprint backfill; SigLIP 2 for uncaptioned clips (50–100 clips, ~20 searches, fixed sampling); text embeddings; larger local text model vs 3B.
7. **People × events;** confirmed events feed compilations.
8. **Integration decision** at each step on the gates.

## 11. Open questions for Rick (one at a time)

1. Cloud use on derived *text* (captions, transcripts): allowed for later labelling steps, or local only?
2. Should confirmed events become visible in the Catalog (tags/folders), or stay inside Events?
3. Which categories matter most beyond the holiday set — music jams, school events, first days, Berklee sessions?
