# A video LLM for the Breen family media: what the two October docs get right, and the first experiment

Research note for Rick · Claude · 29 October 2026

**Recommendation:** do not train a model yet. Both supplied documents, read closely, describe a
*retrieval* system around a frozen vision-language model, not a trained one, and that is the right
shape for VideoScan. Most of their pipeline already exists here under other names. The one
genuinely new idea worth money is the **environment fingerprint** (recurring rooms, cars, furniture
as context across decades). The first experiment is the era benchmark already specified on
10/26, run with a current local VLM; the second is a bounded retrieval test of structured scene
JSON against Rick's 18 confirmed events. Fine-tuning (LoRA) is earned only by the error analysis
those two produce.

Inputs: `SW_Video_LLMs_MediaExpert.txt` (two pieces: a "Family Media Intelligence System"
blueprint and "Video LLM Paradigms for VideoScan") and `video_intelligence_architecture.pdf`
("Modular Video Intelligence Architecture for Apple Silicon & Cloud"). Read against
`docs/DECISIONS.md`, the 10/16 training-guide review, the 10/25 fingerprinting research and the
10/26 provenance design. No model was run and no family media was seen in writing this; the note
was written in a cloud session, which is allowed because it contains no family pixels, audio or
frames.

## 1. The two settled rulings that shape the answer

| Ruling | Consequence for "train a video LLM on our media" |
|---|---|
| **2026-08-16** — family knowledge lives in inspectable data; an LLM is never the authority for a family fact; no family fine-tune as a fact store | Who, when, where and how people are related stay in the catalog, the tree and CyberBrain. A model may *perceive* (what is in the frame, what era it looks like) and *phrase*. It never *remembers* a family fact in its weights, because a wrong weight cannot be corrected through Update… |
| **2026-10-10 / rule 13** — nothing of living immediate family (pixels, audio, frames, face embeddings) goes to a cloud model | Every model that sees a frame runs on the M5 Ultra or the M4. The two docs' cloud tiers (Gemini, GPT-4o, "Claude 3.5 Sonnet", Bedrock) are out, whatever they would save in weeks. This also answers the gift-credit question: cloud Claude designs, reviews and writes tests on synthetic fixtures; it never sees a keyframe. |

Two more that the docs run into: **2026-10-23** (POI face search is no longer the strategy; recognition is frozen) and
**2026-10-14** (a related score is a ladder of evidence, never a weighted sum; confidence words come from evaluated rules,
never a model's self-assessment).

## 2. What the docs propose, and what it is here

| Doc proposal | Here today | Verdict |
|---|---|---|
| Keyframes by scene change, 1 frame per 2–5 s, downsampled; never the raw file to the VLM | `CaptionOrchestrator` + `MLXVLMCaptionRunner`, one 448² frame at a time, Qwen2.5-VL-3B-4bit on MLX-Swift; 4,518 contents captioned (date / scene / text prompts) | **Exists.** The sampling policy is the open question, not the mechanism. |
| Local Whisper for timestamped speech | `AudioTranscriber`; transcripts in the catalog; segment-timestamp re-run is a backlog item (~21 machine-hours) | **Exists.** |
| GEDCOM as ground truth for identity and timeline constraints | `GedcomFamilyGraph`, `GedcomCompiledTree`, kinship paths, identity rulings, FamilySearch refresh | **Exists, and stronger**: the tree is the fact store the ruling demands. |
| "Exact drops" by fuzzy header hashing | whole-file SHA-256 is identity (rule 6) | **Reject.** A header hash is a guess; the catalog already has the proof. |
| Perceptual hashing across containers and re-encodes | `picture-prints.sqlite` (32×32 DCT per second, v2), `audio-fingerprints.sqlite` (25.1 M landmarks), `content_excerpts`, `supersessions` | **Exists.** |
| Semantic hashing (CLIP/SigLIP) for trims and altered intros | MobileCLIP2-S2 on the ANE is the chosen embedding, gated on the 18-event benchmark (10/25 §4) | **Planned, gated.** |
| DBSCAN / hierarchical clustering over time + audio + visual scene | Events groups with Rick's confirm / reject / split in `EventsDecisionStore`; the 10/16 review already found DBSCAN is exploratory grouping, not authority | **Reject as authority, allowed as a candidate generator** that feeds the ladder. |
| Face match (InsightFace/FaceNet) → GEDCOM name, filtered by life span | Vision + AdaFace exist and are frozen (10/23) | **Reject.** The life-span filter is a good constraint on a *proposal*; it does not rescue identity across 40 years. |
| Structured JSON from the VLM: temporal events, visual and audio anchors, era clues, environment fingerprint | Three free-text prompts; `DateTriangulator` fuses dated claims with a written reason; `provenance_assertions` (v13, inferred / confirmed / corrected / rejected, with evidence_json) | **Take the schema idea.** It is the best thing in either doc: each field becomes an assertion with evidence, model id and frame times, never a paragraph. See §4. |
| `confidence_score: 0.95` from the model | ruling 2026-10-14 | **Reject the number, keep the rationale.** Confidence is assigned by a benchmarked rule for that claim kind. |
| Technical DNA profiling (codec, 4:3, interlace, 29.97 vs 24 fps) → camera archetype | 10/25 §7: encoder-signature chains, `idet`, dvrescue `rdt`, telecine cadence, OSD OCR — all deterministic, all cheaper than a model | **Exists in design, and is stronger** than the doc's version. These date a file with evidence; the VLM is the lowest rung under them. |
| Visual anachronism detection (cars, TVs, fashion, toys → year range) | 10/26 §5: an *era* claim kind at confidence ≤ 0.3, ±7 years, below folder year, shipped only if MAE < 7 years on VHS/DV strata | **Planned, gated.** This is experiment 1 (§5). |
| Constraint propagation from a known birth date ("baby walking" → 9–18 months after birth) | `DateTriangulator` already fuses age + birth year | **Exists.** A spoken age plus a birthday candle count is a backlog line. |
| Environment fingerprint: "green shag carpet + oak panelling in 15 videos over 10 years = Grandpa's house" | backlog: "recurring locations as context not identity" | **Take.** The one new idea. Places are stable across decades in a way faces are not; a place is a context, never a name. Experiment 2 (§5). |
| Audio-visual alignment: "look here, Jimmy" + a child in frame → tag the child "Jimmy" probabilistically | CyberBrain testimony; spoken names in transcripts | **Half-take.** A spoken name at a timestamp is testimony worth storing. Attaching it to a visual body is a *proposal to Rick* at best; ruling 10/10 says machine signals never assign names. |
| Object / vehicle / pet continuity as temporal anchors | nothing | **Take as a date bound**, same shape as the era claim: "the red Beetle appears, and Rick says it was sold in 1998" is a ceiling with a human source. |
| LLM converts a question into a Cypher query over Neo4j | Hallie: the model emits a fixed tool schema (`resolve_person`, `relatives`, `search_media`, …), a validator fails closed, executors answer from the catalog | **Reject Neo4j, keep the intent.** Free-form Cypher is unverifiable; a fixed tool schema is the verifiable version of the same thing, and it is already built and paused. |
| Neo4j, MinIO/S3, Qdrant/pgvector, Celery/Redis, Prefect, LangChain/LlamaIndex, FastAPI workers | one SQLite catalog, sidecar SQLite stores, MFO jobs with Pause/Stop and one log sink | **Reject.** Five servers to run a one-user app on one Mac. A vector index for ~9k contents fits in memory at job start, like `AudioFingerprintIndex`. |
| Inference abstraction: `VideoFrameContext → MetadataPayload`, local or cloud behind one interface | `CaptionRunner` is MLX-specific | **Take the seam, drop the cloud leg.** One protocol so Qwen2.5-VL-3B, Qwen3-VL-8B/32B and a Core ML embedder are swappable, each result stamped with engine id and version. The C++ analogy: a pure virtual `Captioner` with one concrete MLX subclass; no cloud subclass is ever linked. |
| Model picks: Qwen2.5-VL 7B/72B, Llama-3.2-Vision 11B, LLaVA-NeXT via Ollama/vLLM | Qwen3-VL (Apache-2.0, native video with timestamps) supersedes all of these; mlx-vlm's video path needs a pinned version | The docs are a year behind; use Qwen3-VL. Whether MLX-Swift's `MLXVLM` takes video input is still unverified (10/25 §5). |

## 3. What "training on our media" would actually mean (unchanged from 10/16)

The ladder in `family_event_learning_review_2026-10-16.md` §5 stands: learning by examples (no weights change) →
a small classifier on frozen features → contrastive adaptation → VLM LoRA for extraction or judgment → never from
scratch. Neither new doc argues for a higher rung; both sit on the first one. The honest training data VideoScan
has is small: 18 confirmed events with 42 members, 73 user-entered dates, and the confirm / reject / split
decisions. That is enough to *evaluate* a frozen model and to fit a logistic regression on frozen features. It is
not enough to LoRA a VLM into anything a benchmark could trust, and a LoRA trained on it would mostly learn the
rooms the family films in, which is what experiment 2 gets for free without touching weights.

When LoRA becomes worth it: when experiments 1 and 2 show the model *sees* the clue but *extracts* it badly
(wrong JSON shape, inconsistent era vocabulary, misses burned-in stamps). That is an extraction error, which a few
hundred curated examples can fix on the Ultra with mlx-vlm, with a held-out split and an explicit model version.
Identity and kinship are never training targets.

## 4. The record shape: structured JSON becomes assertions, not a paragraph

Take the doc's schema, drop its confidence number, and map each field to a `provenance_assertions` row (v13 design,
10/26 §6), one row per field, state `inferred`, `by = machine qwen3-vl-8b:<rev>`, `evidence_json = { frames: [t…],
rationale, prompt_id }`:

| JSON field in the doc | Assertion field | Who may promote it |
|---|---|---|
| `temporal_events[].event_type`, start, end | `occasion_kind` on a content time range (segments are metadata, 10/10) | Rick, via Events membership |
| `visual_anchors`, `audio_anchors` | retrieval text only (joins captions and transcript); never shown as a fact | nobody; it is an index |
| `estimated_year_range`, `technical_clues`, `cultural_clues` | `DateCriterionClaim.Kind.era` at ≤ 0.3, ±7 years, below folder year (10/26 §5) | the triangulator ranks it; Rick dates archived rows |
| `environmental_fingerprint.*` | `place_signature` (free words + embedding), clustered per model revision into place candidates | Rick names a place once; the name is then context, never identity |
| `confidence_score` | dropped | — |

A rejected value is never re-proposed (the `BEFORE INSERT … RAISE(IGNORE)` trigger of the v13 design), which is
what makes machine drafting safe to re-run with a better model.

## 5. The first two experiments, with their red/green

**Experiment 1 — era benchmark (already designed 10/26 §5; run it).**
200 clips with a trusted date, stratified: iPhone era, DV 1995–2005, VHS 1984–95 transfers. Five keyframes each,
one structured era prompt. Report MAE and the share within ±5 years, per decade; per-clip results stay in
`.scratch/` (ruling 10/26). Green: MAE < 7 years on the VHS/DV strata. Red: the era claim kind stays a research
note. Run it twice, Qwen3-VL-8B 4-bit and Qwen3-VL-32B 4-bit, so the size question is answered by numbers. Cost on
the M5 Ultra: about 2,000 prompt calls, hours not days; nothing leaves the machine.

**Experiment 2 — bounded retrieval with structured scene JSON (the backlog line, made concrete).**
For the 42 members of the 18 confirmed events plus 200 distractor contents from the same decades, extract the §4
JSON per scene and embed the `place_signature` and anchor text. For each member, rank every other content by
(a) rules only, (b) MobileCLIP2 frame embedding, (c) scene JSON text + place embedding, (d) b + c. Score
precision at 5 and at 10 against Rick's own confirmations, split by occasion and by lineage so copies do not
inflate the score (10/16 §5). Green: (c) or (d) beats rules on held-out occasions. Red: the environment
fingerprint is a caption field and nothing more. The most valuable negative is another birthday in the same room.

Both experiments are frozen-model, read-only on media, MFO-shaped if they run inside the app, and produce the
error analysis that decides whether rung 2 (a small relation classifier) or rung 4 (LoRA for extraction) comes next.

## 6. What the $79 of cloud credit can and cannot buy

Can: this note; a design doc when Rick says "design it" (the `Captioner` seam, the era claim kind, the
`place_signature` assertion, the two benchmark harnesses); the test suites on synthetic fixtures (the media
matrix, isolation, truth tests of rule 8); an adversarial review of the plan; the mlx-vlm pin and the
Qwen3-VL-video-on-MLX-Swift check against public sources.

Cannot: run either experiment, look at a keyframe, read the catalog, or train anything. Those run on the Ultra, in
Rick's away window on the M4 if they are long.

## 7. One-line verdict on each doc

- **FMIS blueprint:** a generic enterprise RAG stack (five servers, a graph DB, a cloud tier) for a problem VideoScan
  solved with one SQLite file and rulings. Take the structured-JSON idea and the GEDCOM-as-ground-truth stance.
- **Video LLM Paradigms:** the right mental model of how a VLM "watches" video (sampled frames plus timestamps) and
  the one new idea, contextual constellations. Its cloud leg violates rule 13. Its model list is a year old.
- **Modular Video Intelligence (PDF):** a tidy restatement of the 10/25 fingerprinting research with weaker evidence
  (fuzzy header hashing, DBSCAN as authority) and the same cloud leg. The inference-abstraction seam is worth keeping.
