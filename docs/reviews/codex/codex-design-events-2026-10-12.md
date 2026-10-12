# Codex review — Events design (xhigh)

- Range: `7375a5eb5^..7375a5eb5`
- Credits spent: unavailable (billing not exposed)
- Tokens: 45639
- Finding count: 8
- Verdict: fix — revise identity, session authority, and date propagation before implementing the rapid-dev pipeline. The product direction is sound.
- Run: 2026-10-12T17:34:10Z (cycle #66, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (billing not exposed) | Finding count: 8

The direction is right. The central mistake is turning useful clues into authoritative structure too early: versions become one recording, sessions become atoms, and membership becomes permission to inherit dates. The best improvement is to preserve uncertainty through those transitions.

I read all four files. The tab charter and project goals are consistent; my objections concern the inference design.

1. **Identity needs to distinguish “identical recording” from “contains some of the same footage.” — v1**

   [Layer 0](/Users/rickb/dev/VideoScan/docs/design/events_design.md:48) folds versions onto their master. That is safe for verified full-length equivalents, but “version” or lineage alone does not establish that equivalence.

   **Scenario:** A “Breen Christmases” compilation contains excerpts from 1994, 1998, and 2003. Folding it into a master can connect three separate occasions. Another camera’s recording of Christmas 1998 is the same event but contains unique footage.

   **Change:** Collapse byte-identical copies; retain verified A/V pairing. Keep other lineage as typed relationships, with range mappings where known. A compilation remains a distinct recording with several source relationships.

   Preserve observations from *every copy’s location*. One copy may sit in `Christmas1998Westford`; another in `Recovered`. Those are two labels about one witness, not two witnesses.

   Event membership must never itself prove that footage is “covered,” superseded, or safe to discard. That distinction directly protects Rick’s goal of preserving the unique.

2. **Sessions should be provisional context, not indivisible atoms. — v1**

   [The session rule](/Users/rickb/dev/VideoScan/docs/design/events_design.md:50) is deterministic, but determinism does not establish precision.

   **Scenario:** Consecutively numbered VHS transfers were made Tuesday afternoon, but contain ten years of holidays. A phone dump spans weeks. A `Donna birthdays` folder is thematic. Even genuine capture times three hours apart can join a school performance and an unrelated dinner. Successive three-hour gaps can also chain indefinitely.

   **Change:** Make the smallest addressable unit a **recording range**, defaulting to the whole file. Sessions are reversible adjacency suggestions over those units.

   Use trusted capture continuity for strong adjacency; folder plus numbering alone gives a candidate neighborhood. Camera make/model is supporting evidence, not device identity. Bound total session span as well as adjacent gaps. Allow “mixed” and splitting even for short edited files.

   I would reorder the pipeline:

   **Identity + sourced observations, including original dates → provisional ranges and capture runs → category suggestions → instance suggestions → derived-date suggestions.**

   Rick’s decisions constrain every stage. Segmentation and adjacency can refine each other without treating either as settled truth. A session supplies context; each proposed event member still needs inspectable support.

3. **The LLM’s job should be evidence adjudication; model size is an experiment. — v1**

   [The proposed JSON](/Users/rickb/dev/VideoScan/docs/design/events_design.md:56) invites polished speculation, particularly `title`, `people named`, and `confidence`.

   **Scenario:** Whisper produces “happy birthday” over tape noise. A caption calls something a cake. Supplying a family roster encourages the model to complete the story with a plausible name and year. Its explanation then repeats the inputs as if it had independently verified them.

   **Change:** Supply bounded, chronological evidence packets containing source IDs, timestamps, source types, surrounding context, contradictory observations, and explicit coverage gaps. Include neutral samples, not only keyword matches.

   Request multiple possible categories, supporting/refuting evidence IDs, literal name/date mentions, and `mixed`/`insufficient evidence`. Separate “name mentioned” from “person present.” Require unknown values to remain null. Validate citations and constrain names/dates to supplied evidence. Generate titles from validated fields.

   Confidence words should come from evaluated evidence rules, never the model’s self-assessment. “Caption suggests birthday” is more honest than “seen: birthday.”

   Keep 3B as the baseline. Compare a larger local text model on identical packets and held-out cases; choose by errors and cost. These files establish neither model’s adequacy. Larger reasoning cannot recover a detail absent from the captions—targeted local reinspection may help more.

   Also, “a few hundred sessions” is unproven: conservative grouping may leave thousands. Bound packet size and measure throughput. Cloud is unnecessary to unblock v1 and remains subject to Rick’s ruling.

4. **Replace “two of four signals” with occasion-specific support and explicit contradictions. — v1**

   [The merge rule](/Users/rickb/dev/VideoScan/docs/design/events_design.md:59) counts signals without distinguishing their specificity or dependence.

   **False merge:** Two sons have birthday celebrations on successive weekends, in the same room, with Donna present, under `Birthdays`. Folder plus confirmed people passes even with accurate, distinct dates.

   **Missed merge:** One camera shows birthday candles; another shows children playing outside at that same party. Their categories differ, folders differ, and neither has a confirmed face. Only 73 confirmed people hits exist, so that condition cannot carry much archive-wide recall.

   **Change:** Category compatibility helps retrieval; category equality must not be mandatory. Repeated family members and generic folders are weak support. A folder-derived date and that same folder label count as one source.

   Accept verified matching footage **at the relevant ranges**, Rick’s explicit membership, or sufficiently specific corroboration of the occasion. Otherwise retain a proposed link for review.

   Keep the prohibition on uncontrolled chains, but avoid requiring every pair to possess evidence: a weeklong vacation will fail that test. Require direct support to an established event anchor and check the whole group for contradictions. Proposed members cannot become new authorities merely by joining.

5. **Date propagation needs a provenance firewall and should follow review. — v1**

   [“A dated member dates the session”](/Users/rickb/dev/VideoScan/docs/design/events_design.md:61) is the highest-risk inference in the design.

   **Scenario:** A camcorder clock reset to January 1998. OCR reads it correctly in twenty frames. Those repeated readings establish what the overlay says, not when filming occurred. One resulting session date can then seed an event and return as apparent corroboration.

   **Change:** Preserve the original date observations before grouping. Event-derived dates must never count as independent support for the memberships that produced them. Track dependencies so rejecting an anchor invalidates its unconfirmed descendants.

   Repeated OCR, plausible calendar values, and chronological consistency are useful checks; independent corroboration or Rick’s judgment establishes clock credibility. Conflicts should remain visible.

   Distinguish **event duration** from **uncertainty about its date**. A weeklong trip has duration; “sometime in 1998” expresses uncertainty. Neither justifies assigning every member the same day.

   Christmas plus folder year does **not** warrant December 20–31: decorating, school concerts, and delayed celebrations fall outside it. Preserve the year and Christmas association separately.

   Use words such as “directly supported,” “inferred from event,” and “conflicting,” with confirmation separate. For v1, show date previews and require explicit acceptance through the existing date action. Put this after membership review, not before the Events page.

6. **Fifty clip marks are a development set, not an acceptance set for this pipeline. — v1**

   **Scenario:** Rick approves fifty obvious birthday clips, while their grouping silently combines several birthdays. The classifier appears excellent; the product answers “which birthday?” incorrectly.

   The [prototype vote key](/Users/rickb/dev/VideoScan/scripts/events_prototype.py:210) identifies category and content, not a particular instance, membership rationale, or date claim. It also displays only the first 24 members. Its [strength rule](/Users/rickb/dev/VideoScan/scripts/events_prototype.py:184) upgrades three clips to “strong”; that is volume, not calibrated confidence.

   **Change:** Keep those fifty marks for discovery and development. Create a separate acceptance set with:

   - Category judgments, same-occasion/different-occasion pairs, whole-group judgments, and date judgments.
   - Recurring holidays across years, two celebrations close together, themed folders, transfers, compilations, ordinary gatherings, and TV/music mentions.
   - Unretrieved footage, to expose misses, plus completely annotated mixed tapes to measure segmentation recall.
   - All copies, edits, and camera views of an occasion in the same split.

   Even zero errors in fifty independent trials permits roughly a 6% error rate at a one-sided 95% bound. Correlated clips provide less evidence.

   These would be my **provisional pilot gates**, fixed before tuning:

   | Step | Single gating metric |
   |---|---|
   | Identity | False equivalences: zero |
   | Sessions | Contaminated sessions in the challenge set: zero |
   | Segmentation | Distinct-event recall on annotated tapes: ≥90% |
   | Category | Precision at fixed suggestion coverage: ≥90% |
   | Instances | Falsely combined occasions in the challenge set: zero |
   | Dating | Incorrect or unjustifiably precise suggestions: zero |
   | Decisions | Lost/overridden decisions after reruns: zero |
   | Page usefulness | Correct events found per Rick-minute: better than v0 |

   Freeze coverage or proposal counts too, so abstention cannot manufacture a win. These are launch criteria for reviewed suggestions, not evidence of archive-wide reliability.

7. **Hash-keyed corrections are insufficient for range membership and event decisions. — v1**

   [The correction design](/Users/rickb/dev/VideoScan/docs/design/events_design.md:63) promises persistence across rescans and model upgrades, but the proposed key does not express everything Rick can decide.

   **Scenario:** Rick excludes the first ten minutes of a tape from Christmas 1998. A new segmenter changes boundaries. Or he rejects merging two events; their generated IDs change on the next run.

   **Change:** Use durable event identities, source-content ranges, and explicit membership/merge decisions. Preserve “these occasions are different” independently of generated grouping IDs. Distinguish rejecting a category from rejecting an instance membership.

   An analysis rerun must reconcile with those constraints. A genuinely new observation may justify offering reconsideration; a differently worded model answer does not.

   Full automatic transfer of corrections across edited versions can wait until reliable range mappings exist. Make that limitation visible.

8. **The smallest honest v1 is a useful review queue with persistent results. — v1**

   **Scenario:** An attractive Events page produces hundreds of named cards but requires Rick to untangle each one. It has increased archival work.

   **Change:** Start with a few useful categories, including Music/performance, conservative whole-file groups, and timestamped candidate ranges for mixed tapes. Provide playback at the evidence, accept/reject membership, rename, split/merge, manual range adjustment, and durable corrections. Uncertain cross-session links remain suggestions.

   Defer automatic dating, elaborate event hierarchies, exhaustive segmentation, and new embedding backfills until the review loop demonstrates value.

   The [tab charter](/Users/rickb/dev/VideoScan/docs/design/tab_charters.md:44) also promises comparison and master selection. Connect existing Compare Footage and shared actions; grouping alone must not mark clips covered. Confirmed events should remain browsable after their review task is finished.

**I would sign off on v1 if…**

- Recording identity, footage overlap, and event membership remain distinct.
- Every suggestion exposes its evidence and supports inexpensive correction.
- Original dates and derived dates cannot corroborate each other circularly.
- The held-out challenge set passes the pilot gates.
- Rick finds useful memories faster, and his decisions survive reruns.
- Cloud processing and automatic date propagation are unnecessary for launch.

**Ideas ranked by expected value ÷ effort**

1. **Ask high-value questions.** “Same birthday or different years?” beside two representative moments can resolve an entire ambiguous group. Rick’s attention is scarcer than local compute.

2. **Recover existing human organization.** Preserve labels from every copy; inspect Avid bins, FCP projects, tape labels, and sidecars if present. Sequence placement can be evidence of intentional grouping. A highlight reel still needs range-level interpretation.

3. **Search rare phrases and matching audio passages.** Distinctive speech or synchronized sound can retrieve another camera angle or locate an excerpt in its source tape. Treat quoted/reused audio cautiously.

4. **Resample where evidence disagrees.** Spend local vision/audio work around suspected boundaries, conflicting dates, and weakly supported candidates. Compare this against blanket model upgrades.

5. **Learn confirmed recurring locations.** Rick labels a few examples of “Ma’s living room.” Use that for retrieval and context; it cannot distinguish annual occasions by itself.

6. **Make music an explicit activity family.** Separate casual playing, rehearsals, jams, recitals, and recorded music when evidence permits. This serves Rick’s archive beyond the holiday vocabulary.

7. **Combine birthdays with explicit age evidence.** Confirmed birthday subject plus reliably spoken age can suggest a year. A face near a cake does not establish whose birthday it is, and birth date does not establish celebration date.

8. **Diarization, then optional voice identification.** Useful for navigating conversations and recognizing recurring speakers. Diarization alone identifies neither the person nor who operated the camera; place it behind the cheaper gains.

Verdict: fix — revise identity, session authority, and date propagation before implementing the rapid-dev pipeline. The product direction is sound.

## Brief

# Codex brief: Events design — bounce ideas (highest reasoning), not a code review

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …` ("merge" = the design is sound enough to start the rapid-dev steps). Write no files; answer only. Up to ~2,000 words; this is a thinking session, so depth beats brevity where it earns it.

**Rick's ask (10/12):** "We want the best we can do" for grouping the family videos into events — "AGI for Breen home videos", half joking. He explicitly asked for codex at highest reasoning to bounce ideas. You co-wrote the first draft (the Auto-Discover Events doc (10/11; since folded into events_design.md), 10/11); the Manager folded it with a layered grouping design into **one unified document**. Argue with it.

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

## Closure (Manager, 2026-10-12)

All 8 findings accepted into `docs/design/events_design.md` v2 (design only; pinning tests come with the build):
1. Identity: byte-identical + verified A/V pair only; lineage is typed with ranges; compilations stay distinct; membership never means "covered" (§1.3, §3A).
2. Sessions → provisional "capture runs" over recording ranges; span bound as well as gap; pipeline reordered A–F (§3).
3. LLM as evidence adjudicator: bounded chronological packets, cited observation ids, mentions ≠ presence, nulls, validated citations; confidence words from rules; model size an experiment (§3C, §7).
4. Merge rule replaced: compatibility for retrieval, anchor + occasion-specific support, folder date + label = one source, whole-group contradiction check, no chains but no pairwise requirement (§3D).
5. Dating after membership review; provenance firewall; duration ≠ uncertainty; no "20–31 Dec"; previews via the existing date action (§3E).
6. Two sets (development vs challenge), split by occasion; pilot gates table adopted verbatim (§8).
7. Decisions keyed by durable event id + content range; "different occasions" survives regrouping; category rejection ≠ membership rejection (§3F, §6).
8. Smallest honest v1 = review queue with persistent results; deferrals listed (§5). Ideas list adopted and ranked (§9).

## Closed

Closed by `HEAD` at 2026-10-12T17:40:06Z. all 8 folded into events_design.md v2
