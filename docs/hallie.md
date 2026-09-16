# Hallie — family archivist architecture and operations

Consolidated September 16, 2026 from the sources listed below, inspected at
`59ca9468c01e0068501206c63698286c10f4e8b7`. This is a documentation synthesis;
it does not certify a new build, live replay, migration, or deployment. Dates and test counts quoted below describe their original runs.

## Purpose and reading map

Hallie is the conversational interface to the family archive: finding media,
answering sourced questions about people, explaining evidence, and helping
Rick teach the archive what the family knows. The catalog remains a primary
surface; conversational queries should expose useful, editable results there.

The durable rule is **family knowledge lives in inspectable data**. A model
can interpret language or phrase an approved answer. It is not the authority for a family fact, a person's identity, a write, or an action.

Use this document for the common contracts, operating boundaries, and roadmap. Keep these focused specifications beside it:

| Focused document | Why it remains separate |
|---|---|
| [CyberBrain design](cyberbrain_design.md) | Persisted schema, privacy, retrieval, correction and preservation contracts; historical proposal sections remain labeled. |
| [Proposer/tool contract](hallie_proposer_with_tools_design.md) | Typed claims, verification table, tool schemas, budgets, cache and cutover requirements. Read the benchmark correction below before its rev-5 rationale. |
| [Two-mode specification](hallie_two_mode_design.md) | Detailed routing transitions, cross-client wiring and acceptance sequences. Historical line numbers are navigation clues, not current anchors. |
| [Live failure ledger](hallie_live_failures.md) | Exact questions, corpus IDs, fix evidence and unresolved statuses must remain auditable. |
| [Pronunciation research](pronunciation_training_research.md) | Phoneme mappings, prototype evidence, candidate methods and cited research. |
| [Local neural voice](hallie-local-neural-voice.md) | Installation, pinned revisions/checksums, fallback and license provenance. |
| [Qwen measurements](qwen_metrics_2026_08_27.md) | Reproducible benchmark identity, artifact hashes, uncertainty and invalidated-pilot correction. |

Detailed tree ingest/cache and web contracts remain separate: [GEDCOM](gedcom.md), [offline tree cache](offline_family_tree_cache.md),
[FamilySearch API notes](familysearch_api_notes.md), and [web interface](web_interface.md). This document does not redefine their
storage, authentication, export, or serving protocols. September 12–15 code-review and refactoring reports remain independent records.

## Status: decisions, implementation evidence, and proposals

The early August documents described a translator-only read-only slice.
The August 17 grounded-composition document explicitly records implementation;
later notes describe conversation, teaching, galleries, speech and LAN use.
Do not read those early non-goals as permanent exclusions of later features.

| Topic | Status supported by the source record |
|---|---|
| Strict query translation and deterministic execution | Implemented foundation; August 1 P0/P1 and August 14 factual-authority decision. |
| Optional bounded model phrasing | Recorded implemented August 17, with deterministic template fallback. |
| Multi-turn continuity and provenance | Implemented changes documented August 17 and August 21–22; later failures show remaining boundary gaps. |
| Person gallery | September 10 document describes implemented routes, filesystem rules and tests. |
| Catalog/tree mode | Accepted for implementation September 13; mode components and tests exist in the source inventory. This synthesis does not declare every planned phase complete. |
| Partial intent recognizer | September 7 design agreed in principle; source says not started. No completion inferred here. |
| Planner/proposer with tools | Proposed; detailed contract and shadow-evaluation gates retained. |
| Tree text, title and aggregate queries | September 7 proposals; individual capabilities must be checked against their implementation/tests before claiming completion. |
| Research Person | August 29 proposal says Phase 1 in progress; no later completion established here. |
| HallieKit / standalone Hallie.app | August 17 proposal, not a shipped-product claim. |
| Pronunciation drill and phone-ASR verification | Original documents are proposals/research; implemented pieces do not establish all proposed phases. |
| Role-separated model management | September 6 proposal; September 8 note says reviewer model/host selection and local-main tracking subsequently landed. Broader preset policy remains a proposal unless separately verified. |

Latest review handoff: team message **1514** reports three September 15 findings
fixed. That is peer-reported status, not independent validation here; **directory durability remains NOT fixed**. Keep its review finding open.
A design requirement for durable writes must not be reported as implemented merely because a writer uses an atomic rename.

## Question-to-answer contract

The original catalog path remains the simplest expression of the boundary:

```text
sentence → strict NLQuerySpec → normalize → compose visible infix query
         → existing tokenizer/search index → deterministic results and counts
```

An infix-looking query may bypass the model. Applied queries remain visible
and editable in the real catalog search field. Translation failure or an empty
usable spec has an honest literal-search fallback in this original NL path;
that fallback is not permission to turn an unresolved tree person into a catalog keyword search.

Values are data, never grammar. The wire decoder rejects unknown fields, enums, types and oversized lists; normalization strips unsafe syntax and
clamps/drops invalid values; only the composer creates quoting/field syntax.
Round-trip tests use the actual tokenizer to catch structural leakage.

The richer path is:

```text
modal/continuation handling → recognized intent or translated QueryAST
  → identity resolution → deterministic executor → evidence + AnswerPlan
  → template or bounded phrasing → checked result → host-controlled actions
```

QueryAST v2 originally grouped six shapes: presence, temporal, aggregate,
event, graph and cross. Presence uses confirmed tags/dates; temporal uses a
selected record and supported dates; aggregate computes co-occurrence or
other supported arithmetic; graph resolves people/relations; cross requires
both a person and spoken/visible evidence. Unsupported event questions must
be declined, not widened into an easier search. Supported shapes evolve; validation must reflect actual executor capability.

Human tags and machine matches are different evidence. Machine matches carry
tier/engine/score labels; transcripts and captions retain their own basis. Missing evidence is a first-class outcome. A cited answer to the wrong
question is still wrong: validate identity, requested field and scope as well as the truth of each individual sentence.

Core seams include `NLQuery`, `ArchivistQueryAST`, `PersonResolver`, `HallieTurnExecutor`, `HallieAppTurnCoordinator`, `ConversationMemory`,
`HallieAnswerPlan`, `HallieGroundedComposer` and `HallieCompositionVerifier`.
The app, shell and web should share semantic decisions through these seams.

## Identity, continuity, and mode

Keep canonical identity separate from search text and display names. An exact People-profile name can outrank another person's alias; ambiguous
aliases must not widen a media query onto the wrong profile. A resolved
person's safe alternate names can match existing catalog tags, but a spelling claimed by another profile is not silently included.

Owner-relative words such as “me” and “my dad” require the owner pin and the
requested relation. A profile actually named “Dad” is also a valid subject:
“Dad's birthdate” is a property ask, not “father of Dad.” Two people in a
relationship query occupy two slots; they are not automatically candidates for a single which-one question.

An explicitly named missing person must never inherit the previous subject.
Say which person is missing rather than labeling missing identity ambiguous.
Retain stable profile/GEDCOM identity and graph generation across a selected
result and follow-up; converting a selection back to a name loses assurance.
People profiles are authoritative for immediate contemporary family vitals
**per field**: users maintain those corrected values. Do not reopen store
precedence or hardcode historical values from conversations. Imported tree
assertions may disagree and require an explicit bridge. This settled policy
is also recorded in the September 6 Codex handoff; its branch/test/review state is historical and does not establish current findings.

Conversation memory is session state, separate from durable CyberBrain facts.
It tracks prior validated queries, result sets, people, evidence, pagination,
clarifications, offers and repair context. “Show more,” “the one from 1994,”
“and in the 90s?” and “where did that come from?” operate on that state.
No prior result yields an honest request for context, not an invented referent.

The two-mode design makes the question family explicit:

- `unknown`: no settled family; a full general-knowledge sentence need not
  inherit the previous family simply because it follows a biography.
- `catalog`: media, files, counts, search, play and reveal.
- `tree`: people, biographies, relatives and vital facts.

Mode lives in `ConversationMemory`, not persisted defaults. Forced mode is
visible and cleared by reset/Automatic; corrections such as “in the family
tree, not videos” can re-ask the prior question under the corrected scope.
Classifier order considers forced state, explicit scope/cues, identity/file
resolution and then elliptical continuity. Conflicting cues must remain observable; a media noun can outrank a person's name.

A post-translation gate checks AST family against the question/mode. Tree
questions must not fall through to filename searches; catalog asks must not
silently become biographies. Gates also cover deterministic executor fallbacks,
not just the model response. The photo/gallery detection exceptions below matter: not every mention of “photos” means the same source or route.

Count context is distinct from a displayed list. “How many of those are from
the 90s?” carries the prior count scope; a following 80s request replaces the
decade rather than intersecting incompatible ranges. A tree turn or unrelated
non-count catalog result clears that scope. A count alone does not establish an item numbered “second” that can be played.

Tree follow-ups remember actual offered actions. “Show me” with one valid offer can select it; several require clarification; none requires a new
choice. Preserve the person identity in the offer and reject stale identity.
Chaining “their parents” through the relatives just returned, explanations of
photo offers, and titled-ancestor answers were explicit later phases in the two-mode plan, not guaranteed by the mode enum itself.

## Grounded composition and its limits

The August 17 implementation adds an optional rendering step **after** Swift
has produced the factual result. The model sees a bounded approved plan and at most three recent turns, never the entire archive. Translation and
composition have different payloads; the early “model never sees evidence”
wording must not obscure the later explicit AnswerPlan rendering exception.

`HallieAnswerPlan` carries route, subject, shape, claim IDs/text/evidence IDs,
labeled counts, and fallback prose. Presence/cross plans bound item claims
(original maximum 10); CyberBrain plans preserve claim evidence and uncertainty.
Other composable routes derive claims from their deterministic answer. List/fact plans allow up to three sentences, biographies up to six.
Help, declines, clarification, unsupported results, small talk and direct
follow-up actions remain fixed and should not pay for composition.

The documented composer budget is six seconds total, then template fallback.
The original transport used temperature 0.3 and 320 output tokens; app setting
`archivist.composeWithModel` defaults on in that design, shell composition is
opt-in with `--compose`. `archivist.name` supplies the persona name, default
Hallie Mae. These values are documented contracts, not new runtime changes.

Each proposed sentence must cite known plan IDs, such as `[c1][c2]`.
The deterministic verifier rejects untagged/unknown claims and checks years,
numbers and names against the **cited claims**, not the entire answer plan.
Month abbreviations/full names may correspond; unrelated claims cannot vouch
for a leaked relative or place. Sentence splitting must preserve decimals and
filenames. Strictness deliberately rejects unsupported derived counts.
Later recorded hardening rejects literal “Item N”/“claim N” scaffolding;
fragment/coverage restoration was another documented regression target.

Display strips tags; private transcript text retains claim tags and
`composedBy`. Applying phrasing must preserve deterministic basis, citations,
attachments/action authority and clarification semantics. Empty, erroneous,
over-budget or wholly rejected phrasing shows the template.
Token/name checks are bounded validation, not a general proof of semantic
entailment; preserve the behavioral and human-reading tests.

## Knowledge and authoring boundaries

CyberBrain holds attributed family passages, events, anecdotes and sources,
with stable IDs, privacy, confidence, status and supersession. Catalog dossiers
hold evidence about media. GEDCOM holds imported assertions. Reviewed world
facts belong in versioned knowledge data, not arbitrary routing constants.
The [detailed CyberBrain specification](cyberbrain_design.md) remains the
schema/preservation reference; its original August implementation inventory
and proposed migration state are historical.

Qualified dates retain original text and precision (`ABT`, `BEF`, `AFT`, ranges).
Contradictions are shown; retracted/superseded evidence cannot silently support
new answers. Search matching is discovery, not identity resolution.
Privacy is enforced before retrieval leaves the tool/store boundary.
Telling, pronunciation teaching and confirmed research use their explicit
authoring paths; model proposals do not gain write access.

Historical-media feasibility is tri-state: possible, impossible, unknown.
Unknown never vetoes a search/action. Do not revive the old unreviewed
79-year-lifespan shortcut or a categorical “died in 1838 means no photo” rule.
The corrected measurement report records photography policy allowing 1838
within the reviewed 1838–1839 boundary. A possible photograph is not proof
that one exists; a birthplace chain is not proof of migration/residence.

Private transcript location is documented as
`~/Library/Logs/VideoScan/Hallie/hallie-conversation-YYYY-MM-DD.jsonl`.
The contract includes session/sequence, interpretation, route/outcome,
bounded citations, daily UTC rotation, private permissions, symlink rejection
and serialized app/shell writers. It excludes archive/source-document dumps.
Do not change paths or formats as part of documentation cleanup.

## Rich media and person galleries

Attachments are presentation objects, not extra factual authority supplied to
the translator. Lineage/tree cards carry source person IDs; photo/document
bytes are not automatically evidence for a biography. Public surname history
requires a cited source, not a generated story in control flow.

Family photos, crests and GEDCOM originals belong under the designated Master
Archive's `40_Family_Tree/`; app-support thumbnails are derived cache data.
The historical no-Master-Archive fallback is app-support family-tree assets.
These app-managed assets are distinct from scanning media into the catalog.
Refer to the separate tree/storage documents for operational details.

The September 10 gallery contract recognizes “show all photos of X,” “show
me pics of X,” and document/paper asks as a person gallery. Pinned nonmatches
include bare “photos of donna,” two-person forms, and requests with a year;
those retain catalog semantics rather than accidentally narrowing to a folder.

`FamilyAssetStore` reads the unique person's FamilySearch-ID/name folders,
eligible alias folders and group folders. A folder pinned to another record,
a disagreeing birth year, or ambiguous same-name ownership is not adopted.
Read discovery can include multiple attributed folders; write targeting still
requires one unambiguous destination or refusal.
People-only profiles use verified direct children of their reference folder,
cover first. Images must be regular, non-symlink, decodable and revalidated
at display time; JPEG/PNG/HEIC/TIFF are documented formats.

Documents are direct regular non-symlink files with extensions
`pdf`, `txt`, `rtf`, `md`, `doc`, `docx`; chosen-photo and not-of sidecars are
excluded. Gallery handling does not read their text to invent facts.
The documented web attachment route uses capabilities, descendant checks and
a 48 MB cap; the separate web spec owns that serving contract.

Gallery ordering is photos first, chosen portrait first, then documents.
The chat caps displayed photos at 24 while reporting total/remaining count.
Three or more photos use a thumbnail grid; Mac actions can open/reveal folders.
A biography with at least two available files may offer the gallery after
composition; the offer must not alter the factual plan.
“Yes” selects the single gallery offer; “no/not now/cancel” clears it with a
neutral acknowledgement; another question drops it. The documented web flow
uses chip selection. Declined biographies and empty impossible-photo cases must not manufacture offers.

## Shell, voice, and pronunciation

`scripts/hallie` enters the built executable's shell path before SwiftUI,
using read-only catalog loading. The original single-turn exit contract is
0 factual answer, 2 unavailable catalog, 3 no evidence/source, 4 unsupported
shape, 5 translation failure. `--once` supports noninteractive use;
explicit photo/media commands control local opening. Respect the repository's
current machine-routing policy before any app-binary evaluation.

The shell's documented terminal editor supports 100 session-history entries,
arrow recall/editing, Ctrl-A/Ctrl-E and Backspace, including CSI/SS3 cursor
variants. Piped input retains ordinary line reading; terminal settings are
restored before an answer. This is usability history, not a new smoke result.

Optional local Kokoro speech runs in a separate helper process and falls back
to an installed Apple voice. The retained [voice guide](hallie-local-neural-voice.md)
contains `scripts/install_hallie_kokoro.sh`, prerequisites, install location,
pinned artifacts and checksums. Normal speech is local and independent of
Ollama; the original helper renders a whole answer before playback.

Pronunciation authority is Rick's explicit judgment, followed by read-back.
The drill proposal derives normalized given names/surnames from profiles and
tree, prioritizes close family, excludes taught entries and records
untested/judged-ok/taught/alternatives. Deterministic responses handle right,
no, either, skip and one-off teaching. A verification manifest carries expected
phones/respellings; public OSLog should contain counts/source types, not names.

Respelling is lossy because G2P guesses again. The research recommends storing
chosen phonemes and retaining a respelling fallback. Kokoro/Misaki accepts
`[Latta](/lˈætə/)`; its alphabet is not arbitrary IPA. Do not send that markup
to Apple fallback speech. Candidate selection stays human-confirmed;
recorded speech can rank candidates, never automatically replace the choice.
Phone-ASR margin checking is proposed for drift detection; ordinary STT
round-trips normalize names and are weak pronunciation truth tests.
The retained research has mappings, waveform observations, phased schema
proposal and external references; no model/dependency installation is implied.

## Model configuration and measurements

Separate Hallie selection from developer-review selection. Choosing a common
artifact deliberately is different from inheriting another role's setting.
The September 1 “one model for everything” recommendation and projected
hardware/residency claims are historical; they do not establish today's best
model, fleet assignment, concurrency budget, or deployment.

The September 6 policy proposes evaluated Hallie presets plus explicit
Advanced experimental choices. Installed (`/api/tags`), resident (`/api/ps`),
compatible, evaluated and available are separate states. Discovery must not
pull/unload models, change selection, or send family content. A generation
probe can load weights and is an explicit operation.

Capture a configuration revision per turn: endpoint/provider, model identity,
observed digest/backend, budgets and permitted fallback. A changed artifact
invalidates evaluated status; a late readiness response cannot certify a newer
selection. Always validate actual responses even after a successful probe.
Keep credentials out of logs/exports. Local URL syntax does not prove local
execution: a cloud-proxy backend still needs explicit family-data consent.
No silent cloud escalation on local failure.

VideoScan owns requests, cancellation, validated responses, provenance and
selection. Admin tooling owns service lifecycle, installations and fleet
scheduling. Reconnect is not reload; targeted reload is not stop-all.
Reviewer scripts use independent explicit model/endpoint settings, bounded
work and honest failed/skipped status; failed work cannot advance the review
baseline. Automated review stays advisory.

Ollama retention is not a reservation or priority guarantee. Separate aliases,
ports or processes still share a Mac's GPU/memory; measure coexistence or
schedule a suitable separate host/quiet window. Never infer a remote host's
capacity from the client Mac. Current repository machine policy takes
precedence over dated overnight or future-M5 plans.

Historical evidence, not current rankings:

- August 1 NL audition: 13/15 strict on qwen3.6 35B-A3B NVFP4; “the boys”
  exposed the difference between a named-person tag and keyword recall.
- August 27 first-plan benchmark: 44 synthetic/public questions × three seeds;
  native tools 109/132 (82.6%), compatible JSON 103/132 (78.0%). Both passed
  that initial-plan safety gate; ambiguity/abstention remained weak.
- The later **0/16 two-turn pilot is invalid for model-quality/transport
  selection**: final status enums were underspecified and native started cold.
  Nineteen of 32 cases exhausted 20 seconds; one native privacy violation was
  real. Injection robustness remained unevaluated. No corrected live rerun
  was included. This correction supersedes the proposer's stronger rev-5 claim.
- September 1 notes reported 77% versus 78% over 214 Hallie questions and a
  saturated 29-task fitness corpus. Those measures do not rank current models.

Preserved official references: [Ollama tags](https://docs.ollama.com/api/tags),
[running models](https://docs.ollama.com/api/ps), [FAQ](https://docs.ollama.com/faq),
and [Qwen3-Coder-Next card](https://huggingface.co/Qwen/Qwen3-Coder-Next).
These were source-document references, not newly checked product claims.

## Unfinished design directions

### Partial intent recognition and planner/proposer

The agreed-in-principle recognizer has three outcomes: recognized, abstain,
conflict. It claims a sentence only when it accounts for the **full supported
semantic shape**, including constraints. “When did he marry?” cannot become
a birth-date query; “how old when he died?” is derived age, not death date;
a compound ask cannot silently lose one clause.
Start in shadow mode, compare held-out wrong-operation rate and coverage,
then promote one intent family at a time. Track abstention: near-zero can
mean overclaiming. Entity resolution needs equivalent missing/ambiguous
honesty rather than unconditional carry-over.

The proposer design separates one model ToolPlan, deterministic bounded
execution, optional typed claim proposal, and Swift re-derivation/composition.
Tools are read-only. Claims cite exact source IDs; unverifiable/contradicted
facts are dropped rather than hedged. Inference requires verified premises,
an approved kind and explicit labeling; it cannot authorize actions or writes.
Shared guard policy applies equally to the proposed and fallback lanes.

The retained specification defines privacy at tool boundaries, registered
capabilities, ≤6 planned calls, per-result and aggregate prompt budgets,
end-to-end deadline/cancellation, and revision/privacy-keyed bounded caching.
Do not use the older implementation-plan instruction to delete a regex route
immediately on category cutover: later revision requires disabling first,
retaining code/tests until deterministic fallback is adequate and two cutover
cycles show zero fallback-to-regex events.
Proposed gates include ≥200 questions/category, ≥3 repeats, corpus/model/
prompt/schema identity, zero unverified facts, latency/fallback reporting,
privacy/injection tests and 100k-record costs. These are targets, not results.
Inference visibility, optional-key loader policy, heuristic registry, WorldFact
resource placement and remote-private-context policy remain explicit design
choices; the old dated week-by-week schedule is not a completion ledger.

### Tree discovery, titles, aggregates, and research

Literal tree-text discovery can reuse `sidebarRows(containing:)` over primary/
alternate names, surnames and IDs. Bound/page matches and preserve selected
identity plus tree generation. Contiguous case-insensitive search does not
promise reordered tokens, diacritic folding or title synonyms. Do not broaden
the ordinary person resolver to every matching substring.

The titled-ancestor audit corrected its own claim: person-level GEDCOM `TITL`
**does exist**, with 2,431 tags in Rick's then-current export and 4,424 in
Donna's; other `TITL` tags belong to source/media records. The proposed parser/
schema preservation gate stands. Name-string title recognition is complementary:
ordinal+rank, rank+of+place, or opening honorific; bare King/Knight/Earl surnames
are insufficient. Audit counts came from different snapshots and must not be
combined with the aggregate prototype as one population.

Ancestor scope requires a resolved root and traversal; “in the tree” includes
collateral people. A maternal chain differs from all maternal-side ancestors.
Say “the imported tree records…” for historical titles/descent; the tree does
not authenticate a medieval lineage or infer birthplace from territorial names.

Aggregate proposals include place/year/scope filters, count, bounded list,
average/median/extremes and groups. Every statistic states its recorded-data
denominator and missing fields. Unknown filters and zero results cannot be
dropped into a broader answer. Historical/ambiguous places remain as recorded.
Place-to-place generation distance shows the actual chain and which crossing
was chosen; a shortest crossing is not implicitly the only family history.
Open product choices included default tree-vs-ancestor scope, list page size
and copy/export behavior. First proposed slice: place filter, count and list.

Research Person proposes a FamilySearch-ID-keyed dossier (UUID fallback),
source URL/retrieval date/excerpt, verdict (unreviewed/confirmed/plausible/wrong)
and family lore. Contemporary People profiles never go to external research.
Only confirmed findings become cited CyberBrain attestations; model summaries
need sentence citations. Proposed adapters include LoC newspapers, Find a Grave,
Wikipedia/Wikidata and bounded cached web search; availability/terms are not
newly verified. Fixture tests, cancellation, verdict isolation and privacy
guards precede deployment; authenticated hints/images and batch research follow.

### Separate product and family publication

HallieKit/Hallie.app remains a proposal: a versioned read-model/snapshot seam,
host-owned play/reveal/tree actions, independent process/settings/transcript,
and read-only family mode with a family privacy ceiling. It must never write
`catalog.json`; authoring uses separate confirmed CyberBrain operations.
The proposed URL action channel and standalone packaging are not established as shipped by these notes.
A related publication proposal adds record visibility and cited segment ranges;
it requires enforcement at serving **and** tool retrieval, not only the prompt.
Family opening was gated on privacy tests, publication support and sufficiently
broad repeated zero-unverified-fact evaluation, not merely two quiet weeks.

## Regression evidence and source provenance

Keep live examples with corpus IDs in the [failure ledger](hallie_live_failures.md)
and machine-consumed corpora (`hallie_testbed.jsonl`, evaluation/interaction/
strict JSON/JSONL datasets). Documentation retirement never removes datasets.
A ledger row is closed only with regression evidence; mixed dated OPEN/FIXED
paragraphs are not a reliable current release checklist.

The August 28–29 spot-test record adds preservation cases: explicit common
ancestor over spouse shortcut; owner/name disambiguation; year/place which-one
replies; repair turns; typo-tolerant tree focus; full biography fields; missing
versus needs-recompile tree; “our” referents; composition fragments; nickname/
surname discovery; People relationship overview; canonical photo consistency;
pronunciation hints/queries/precedence; duplicate-parent warnings; kin-word
profile properties; and stale namesake-order tests/conflicting profile data.
These are historical observations, not a claim that all remain open or fixed.

The August 21–22 cycles reported 71→77% on one corpus and 92→94% on another,
with final 345-test battery and one labeled eager-load issue (#567). Different
graders/denominators were explicitly not comparable; even a birth-date answer
to a wedding-date question had been scored clean. Preserve production-path,
identity, requested-field, missing-turn and human-reading checks, not score alone.
Logic, scale (100k when traversing records), media matrix when opening media,
poisoned-state isolation, and a production regression sensor remain the bar.

Original documents consolidated here are recoverable from Git at the revision
above, using `git show <revision>:docs/<filename>`; original headings, dates and
source pointers are preserved here as provenance rather than active task orders:

| Original source | Material preserved |
|---|---|
| `family-archivist-design.md` (Aug 1) | NL safety/editability, audition, tokenizer tests, catalog purpose. |
| `family-archivist-phase1.md` (Aug 5–17) | Six shapes, factual authority, identity, shell/continuity and photo boundaries. |
| `hallie_grounded_composition.md` (Aug 17) | AnswerPlan, verifier, bounded rendering, settings, logs and fallback. |
| `hallie_detachment_design.md` (Aug 17) | Read-model/product separation proposal and family mode. |
| `hallie_overnight_2026-08-22.md` | Historical cycles, corpus limitations, regression lessons and terminal editor. |
| `hallie_rich_media_plan_2026-08-22.md` | Attachment/source boundary and Master Archive asset decision. |
| `hallie_implementation_plan_2026_08_27.md` | Unresolved decisions, deterministic-first phases and publication gates; obsolete immediate-delete plan corrected. |
| `hallie_spot_test_misses_2026_08_28.md` | Regression categories, ownership/identity/photo/pronunciation lessons. |
| `pronunciation_drill_design.md` (Aug 29) | Human attestation, derived drill, read-back, manifest and privacy. |
| `research_person_design.md` (Aug 29) | Stable dossier, external-data privacy, verdicts and cited attestation proposal. |
| `model_strategy_2026_09_01.md` | Historical results and superseded role/hardware assumptions. |
| `hallie-model-management-policy.md` (Sept 6, note Sept 8) | Role isolation, configuration revision, privacy, lifecycle and evaluation requirements. |
| `hallie_intent_recognizer_design.md` (Sept 7) | Full-shape recognizer, abstain/conflict, shadow comparison and unresolved identity. |
| `hallie-ancestry-text-search-review.md` (Sept 7) | Literal discovery, stable follow-ups and traversal honesty. |
| `hallie_titled_ancestors_design.md` (Sept 7) | TITL correction, structured preservation gate and recorded-claim wording. |
| `hallie_tree_aggregate_queries.md` (Sept 7) | Denominators, scope, place uncertainty, chain distance and open UI choices. |
| `hallie_person_gallery.md` (Sept 10) | Read/write attribution, formats, bounded presentation and offers. |
| `codex-handoff-2026-09-06.md` (Sept 6) | Settled per-field contemporary People-vitals authority; historical review states are not current findings. |
