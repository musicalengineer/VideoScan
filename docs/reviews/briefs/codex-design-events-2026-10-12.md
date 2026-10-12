# Codex brief: Events design — bounce ideas (highest reasoning), not a code review

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …` ("merge" = the design is sound enough to start the rapid-dev steps). Write no files; answer only. Up to ~2,000 words; this is a thinking session, so depth beats brevity where it earns it.

**Rick's ask (10/12):** "We want the best we can do" for grouping the family videos into events — "AGI for Breen home videos", half joking. He explicitly asked for codex at highest reasoning to bounce ideas. You co-wrote the first draft (`docs/Auto_Discover_Events_in_Media.md`, 10/11); the Manager folded it with a layered grouping design into **one unified document**. Argue with it.

**Read only these:**
- `docs/design/events_design.md` — the unified design (the subject)
- `docs/design/tab_charters.md` — where Events lives (Triage ▸ Events) and the tab rules
- `scripts/events_prototype.py` — the v0 prototype that produced 308 candidate events from Dossier captions + Whisper transcripts + dates + folder names (copies collapsed by full SHA-256)
- `docs/project_goals.md` — Rick's goals; the tie-breaker

**Do not explore outside these files.** Facts you may rely on from the design's evidence table: 11,912 active recordings; 8,323 with scene captions; 6,712 with transcripts; 2,597 with OCR date candidates; 976 detected-people hits (73 confirmed); 3,183 A/V pair halves; 7,621 footage-lineage links; 355 files over 30 minutes; 4,528 with no date. Local models available: Qwen2.5-VL-3B (4-bit, MLX), Whisper medium (MLX), Apple Vision; an M5 Ultra 96 GB for experiments; cloud Claude is available but family pixels/audio/faces never leave the machine and cloud on derived text needs Rick's ruling.

**Questions, in priority order:**
1. **Is the layer order right?** Identity → sessions → segments → category → instances → dating → Rick's decisions. Would you reorder, merge or drop a layer? Where is the design doing more work than the evidence can support?
2. **Sessions as atoms.** The claim: deterministic capture-adjacency grouping (folder, clip numbering, camera, time gap) gives high-precision atoms, and models only label them. Attack it: where does it fail on family footage (tape transfers, re-digitized VHS with transfer dates, phone dumps spanning weeks, folders curated by theme not time)? Propose the smallest fix.
3. **The LLM-per-session step.** One local Qwen call per session returning JSON (category, title, date clues, people named, confidence word, why). Is a 3B 4-bit model enough for this, or is the right move a larger local model on the M5, or text-only cloud (pending Rick's ruling)? What prompt/evidence shape gives the best honesty (no invented names/dates)? How do we keep it from laundering a keyword hit into "confidence"?
4. **Instance merging rule.** "Category matches AND two of {dates within window, same folder label, same confirmed people, footage lineage}; reliable date conflict blocks; no chains." Find the false-merge and the missed-merge this rule produces on a real family archive and fix the rule, or argue it's fine for v1.
5. **Dating back-propagation.** Events dating undated files (4,528 of them) through the existing inferred-date path with a shown reason. What guardrails stop one wrong date overlay from mis-dating a whole session? How should ranges and confidence words be chosen?
6. **Evaluation.** Rick will mark ~50 clips ✓/✗ on the prototype page. Is that enough to set pass bars? What should the acceptance set look like so we are not fooled (hard negatives, split by tape, holiday recurrence)? Which single metric should gate each step?
7. **Ideas we have not had.** Given this evidence inventory, what would a best-in-class team do that this design misses? (E.g. speaker diarization to tell who is filming; recurring-location fingerprints "Ma's living room"; using the people graph's birthdays to turn "happy birthday" + a confirmed face into a dated instance; music/jam detection from Rick's own recordings; using Avid bins and FCP projects as human-made event groupings.) Rank by value ÷ effort for a two-person team with plenty of local compute.
8. **Smallest honest v1.** What is the least we should build before the Triage ▸ Events page earns its place in the app?

**Output:** numbered findings, each with: the problem, a concrete family-archive scenario, the proposed change, and whether it belongs in v1 or later. Then a short "I would sign off on v1 if…" list. Then a ranked "ideas" list for question 7. End with `Verdict:`.
