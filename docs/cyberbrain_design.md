# CyberBrain — Breen family knowledge architecture

Status: **PROPOSED FOR REVIEW**

Date: 2026-08-16

Director: Rick Breen

Working product name: **CyberBrain**

Descriptive name: **Breen Family CyberBrain**

## 1. Purpose

CyberBrain is Hallie Mae's private, durable knowledge layer for the Breen
family archive. It combines family-tree facts, curated biographies, attributed
anecdotes, archive evidence, and conversational context without training those
facts into a language model.

The central rule is:

> Family knowledge lives in inspectable data. A language model may interpret a
> question and phrase an approved answer, but it is never the authority for a
> family fact.

This makes the archive correctable, citable, portable, private, and useful long
after today's model has been replaced.

CyberBrain is not a second media dossier system. Video dossiers describe what
can be seen, heard, or inferred in a media file. CyberBrain describes people,
relationships, life events, stories, and the evidence supporting those claims.
The two systems meet through citations and stable identities.

## 2. Why not train a Breen-family model?

A family-specific fine-tune is a poor primary fact store:

- learned facts cannot be inspected or corrected individually;
- recall is probabilistic, with no reliable source citation;
- corrections require retraining and revalidation;
- a small model may blend similar people, dates, and stories;
- family facts can leak into generated answers outside their intended context;
- the model artifact is harder to preserve than JSON, GEDCOM, text, and media.

A future LoRA or small fine-tune may teach Hallie vocabulary, tone, and family
expressions. It must not become the authoritative source of family history.

## 3. Existing foundation

The current app already provides useful pieces, but not yet a CyberBrain:

- `GedcomFamilyGraph` reads names, sex, birth/death dates, and nuclear-family
  links from the newest private GEDCOM file.
- People profiles provide canonical names, aliases, birth/death dates, notes,
  and portraits.
- Catalog records provide confirmed people, inferred dates, captions,
  transcripts, places, objects, and playable media citations.
- QueryAST v2 and deterministic executors keep the model away from factual
  archive evidence.
- Biography answers currently use a small GEDCOM-only semicolon template.
- Hallie has transcript display but no general multi-turn conversation state.

CyberBrain should extend these seams rather than introduce an unconstrained
agent or a second identity system.

## 4. Architectural overview

```text
private source material
  GEDCOM   biographies   anecdotes   oral histories   archive/media evidence
       \        |           |              |                    /
        \-------+-----------+--------------+-------------------/
                                |
                                v
                      CyberBrain loader/validator
                                |
                     stable identity + claim index
                                |
                                v
user question -> QueryAST -> deterministic retrieval -> AnswerPlan
                                                     facts + sources
                                                     uncertainty
                                                     privacy
                                                     suggested actions
                                                           |
                                     deterministic composer | optional renderer
                                                           v
                                                Hallie answer + citations
```

The first implementation remains entirely deterministic. A constrained local
model renderer can be evaluated later, after `AnswerPlan` exists and can bound
every claim the renderer is allowed to express.

## 5. Source hierarchy

CyberBrain does not flatten all text into an undifferentiated search corpus.
Every claim retains its origin and evidentiary status.

Suggested source types:

1. `officialRecord` — civil, military, church, census, or other identified
   documentary record.
2. `gedcom` — imported family-tree assertion, including its original pointer
   and GEDCOM source citation when available.
3. `firstPerson` — a person describing their own life or memory.
4. `familyWitness` — a named relative or participant describing an event.
5. `curatedBiography` — an editor-approved biographical passage.
6. `mediaEvidence` — a catalog record, transcript segment, caption, photograph,
   or other inspectable archive item.
7. `profileNote` — an existing People-profile note, admitted only when explicitly
   curated into CyberBrain.
8. `inference` — a conclusion derived from other evidence, labeled as such.

Source type alone does not decide truth. A first-person memory can be valuable
and uncertain; an imported GEDCOM can contain transcription errors. Hallie
must preserve those distinctions.

## 6. Core data model

The persisted format should be versioned, additive JSON stored outside the Git
repository. The following is the proposed logical schema, not final Swift
syntax.

```text
CyberBrainArchive
  schemaVersion
  archiveID                 "breen-family"
  displayName               "Breen Family CyberBrain"
  people[]
  sources[]

CyberBrainPerson
  id                        durable CyberBrain identity
  gedcomPersonID?           pointer into the imported GEDCOM
  profileStableID?          durable People-profile identity when available
  canonicalName
  aliases[]
  biographyPassages[]
  anecdotes[]
  lifeEvents[]
  terminology[]             e.g. "the boys", "Nana's house"

CyberBrainItem
  id                        immutable item identity
  kind                      biography | anecdote | event | note
  text                      human-curated assertion or narrative passage
  subjectPersonIDs[]
  eventDate?                qualified date, never forced to false precision
  place?
  sourceIDs[]               at least one source for a factual item
  confidence                confirmed | probable | uncertain | disputed
  privacy                   private | family | public
  status                    active | superseded | retracted
  supersedesItemID?
  createdAt
  updatedAt

CyberBrainSource
  id
  type
  title
  attribution?
  sourceDate?
  locator?                  relative document path or stable media record ID
  notes?
```

### 6.1 Stable identity

Display names are not identities. CyberBrain uses its own durable person ID
and records explicit bridges to GEDCOM and People-profile identities.

- A renamed person retains the same CyberBrain ID.
- Aliases are lookup terms, not competing records.
- Two people with the same name remain distinct.
- A missing or ambiguous bridge fails closed and asks Rick to resolve it.
- No code may join people solely by lowercased display name.

The current `POIProfile.id` is derived from the person's name and therefore is
not durable enough by itself. Before CyberBrain treats it as a permanent
foreign key, People profiles need a persisted UUID migration or CyberBrain
must maintain an explicit, reviewed bridge.

### 6.2 Dates

Dates need a qualified representation rather than a single `Date`:

```text
value       "1944-06"
precision   day | month | year | decade | unknown
qualifier   exact | about | before | after | between
displayText "about June 1944"
```

The original source text is retained. Hallie must not convert `ABT 1944` into
the confident statement `in 1944` without preserving the qualification.

### 6.3 Corrections and disagreements

History is corrected; it is not silently overwritten.

- Editing an uncontroversial typo may update an item in place.
- Changing the meaning creates a new item that supersedes the old item.
- A retracted item remains available for audit but cannot support an answer.
- Conflicting active claims remain visible as `disputed`; Hallie reports the
  disagreement and cites both sides instead of choosing one.

### 6.4 Privacy

Privacy applies at the item level, not just the person level.

- `private`: visible only to Rick's local administrative session.
- `family`: eligible for an authenticated family experience in the future.
- `public`: safe for explicitly exported public material.

The first app version is local-only and may read all three levels. Privacy is
still recorded now so future export or web work cannot accidentally treat all
loaded knowledge as shareable.

## 7. Filesystem and preservation layout

Proposed private location:

```text
~/Library/Application Support/VideoScan/cyberbrain/
  cyberbrain.json
  sources/
    interviews/
    biographies/
    documents/
  imports/
  backups/
```

The existing GEDCOM remains under:

```text
~/Library/Application Support/VideoScan/family-tree/originals/
```

Rules:

- no living-family data is committed to Git or bundled into the app;
- paths stored in JSON are relative to the CyberBrain root;
- loaders reject symlinks, traversal, files outside the root, oversized input,
  unknown schema versions, duplicate IDs, and dangling references;
- writes use a temporary file, full validation, atomic rename, and synchronous
  durability before reporting success;
- routine catalog bundles eventually include a separately identified,
  checksummed CyberBrain payload, but bundle export/import is not part of the
  first read-only slice;
- human-readable JSON and source documents remain the preservation format;
  indexes are disposable and rebuilt from those sources.

## 8. Retrieval contract

CyberBrain retrieval produces evidence, not prose.

```text
CyberBrainQuery
  requested person/people
  requested topic or relationship
  optional time/place scope
  privacy ceiling
  result limit

CyberBrainEvidenceSet
  resolved identities
  GEDCOM facts
  biography items
  anecdotes
  life events
  matching media citations
  contradictions/missing evidence
```

Retrieval ordering is deterministic:

1. resolve identity;
2. apply privacy and active-status filters;
3. collect direct facts and explicitly linked evidence;
4. collect relevant archive/media evidence;
5. surface contradictions and uncertainty;
6. rank by relevance, confidence, source quality, and stable tie breakers;
7. enforce bounded results and citation counts.

Substring matching is not identity resolution. Search terms can find passages,
but family identities must pass through the shared resolver.

## 9. AnswerPlan: the boundary before Hallie speaks

Hallie's factual output should be driven by a typed plan:

```text
AnswerPlan
  subject
  answerState               answered | ambiguous | noEvidence | disputed
  claims[]                  exact allowed claims with evidence IDs
  uncertaintyStatements[]
  sourceCitations[]
  mediaCitations[]
  suggestedFollowups[]
  permittedActions[]        play | reveal | narrow | showSource
  forbiddenClaims[]         useful for renderer validation and tests
```

Initially, Swift turns this plan into warm but deterministic prose. Later, an
optional local voice renderer may reorder or paraphrase only the claims in the
plan. Its output is accepted only if every factual assertion maps back to an
allowed claim. Failure falls back to deterministic prose.

Qwen never receives the entire family archive. It receives either the user's
question for QueryAST translation or a small, redacted AnswerPlan for a future
rendering step.

## 10. Conversation state

CyberBrain knowledge and conversational memory are separate concepts.

```text
CyberBrainConversationState
  priorQueryAST
  resolvedPersonIDs[]
  activeEvidenceIDs[]
  activeMediaRecordIDs[]
  selectedDate/place/topic?
  pendingClarification?
  turnSummary
```

This state enables:

- "What about 1994?"
- "And Timmy?"
- "Who was her mother?"
- "Tell me more about that."
- "Why do you think that?"
- "Show me the source."

Referents are stored as stable IDs, never merely as pronoun text. Each follow-up
is reduced deterministically into a new query before execution. The translator
may propose a delta, but it cannot silently replace an established identity.

## 11. Biography behavior

A biography is a synthesis, not a concatenated database row. The deterministic
biography planner should prefer this order when evidence exists:

1. identity and relationship to the family;
2. qualified birth/death information;
3. parents, siblings, spouse, and children relevant to the question;
4. curated life summary;
5. a small number of representative anecdotes;
6. places, occupations, service, interests, or milestones;
7. representative photographs or playable media;
8. source and uncertainty summary;
9. one useful follow-up invitation.

It must not:

- infer personality from a face, filename, or isolated media caption;
- turn a machine caption into a biographical fact;
- describe a qualified GEDCOM date as exact;
- use sentimental death phrasing unless it is an explicitly curated family
  preference;
- dump every known fact or anecdote into one answer;
- expose private material through a lower-privacy interface.

## 12. Editing and ingestion

The first useful editor can be deliberately modest:

- choose or create a person;
- link the person to GEDCOM and a People profile;
- add a biography passage or anecdote;
- identify the source and attribution;
- choose confidence and privacy;
- preview exactly how Hallie could cite it;
- validate and save atomically.

Potential importers, in order:

1. existing GEDCOM facts and GEDCOM source records;
2. explicitly selected People-profile notes;
3. Markdown or JSON biography files;
4. interview/oral-history transcripts with human-approved excerpts;
5. selected catalog media and transcript timestamps;
6. document OCR, always requiring review before becoming a factual claim.

No importer promotes machine output directly to `confirmed`.

## 13. Phased implementation plan

### Phase 0 — contract and fixtures

- approve this document and vocabulary;
- settle durable People-profile identity migration;
- define Codable schema and strict validation errors;
- create synthetic, non-family fixtures for tests;
- build a Rick-reviewed biography/answer quality rubric.

Exit gate: the same fixture can be decoded, validated, indexed, queried, and
rendered deterministically with exact evidence IDs.

### Phase 1 — read-only CyberBrain vertical slice

- implement `CyberBrainArchive`, loader, validator, and immutable index;
- merge newest GEDCOM with a manually authored CyberBrain JSON file;
- route graph biography/birth/death/kinship through CyberBrain evidence;
- produce `AnswerPlan` and deterministic biography prose;
- show knowledge-source citations in app and Hallie CLI;
- preserve the existing GEDCOM-only answer when no CyberBrain file exists.

Exit gate: "Who is Ellen?" can combine GEDCOM facts with a curated passage and
an attributed anecdote, while "Why?" or "show the source" exposes the exact
supporting items.

### Phase 2 — conversation and unified identity

- persist typed conversation state for the active Hallie session;
- support deterministic pronoun, ellipsis, correction, and refinement turns;
- use one identity resolver across presence, temporal, aggregate, graph, and
  CyberBrain routes;
- connect biographies to confirmed media appearances and playable citations;
- implement event and cross-evidence executors rather than declining them.

Exit gate: a five-turn conversation can retain identity and evidence without
retranslation inventing a new referent.

### Phase 3 — authoring and source enrichment

- add a local CyberBrain editor with validation and preview;
- import GEDCOM `PLAC`, `SOUR`, `NOTE`, occupations, residences, and events;
- ingest approved oral-history excerpts and document references;
- add contradiction, supersession, and audit-history UI;
- include CyberBrain in catalog backup/export with explicit privacy controls.

Exit gate: Rick can add, correct, retract, and source a story without editing
JSON by hand or rebuilding the app.

### Phase 4 — archivist voice renderer

- create a reviewed corpus of at least 100 single- and multi-turn questions;
- grade factual fidelity, citations, uncertainty, continuity, warmth, and
  usefulness independently;
- audition deterministic discourse improvements first;
- optionally evaluate Qwen as a constrained AnswerPlan renderer;
- validate rendered claims and retain deterministic fallback.

Exit gate: no unsupported factual assertion in the acceptance corpus and a
reviewed archivist-quality score of at least 17/20, including full marks for
factual fidelity, provenance, and conversational continuity.

### Phase 5 — optional family-language model

- generate training examples from verified AnswerPlans, never raw private
  archive dumps;
- consider a small style/terminology LoRA only if it beats prompting on the
  same blinded corpus;
- keep all factual retrieval outside the fine-tuned model;
- document deletion, backup, portability, and privacy of the model artifact.

This phase is optional. A strong CyberBrain does not depend on it.

## 14. Testing requirements

CyberBrain follows VideoScan's five-dimension feature checklist.

### Logic

- strict schema decoding and version rejection;
- stable identity and alias resolution;
- GEDCOM/profile/CyberBrain bridge ambiguity;
- qualified dates and deterministic ordering;
- confidence, privacy, supersession, retraction, and contradiction behavior;
- exact claim-to-citation correspondence;
- renderer validation and deterministic fallback.

### Scale

- 100,000 people/items through pure indexing and candidate planning with an
  explicit Release time budget;
- bounded query results and citations;
- no O(all knowledge) work in SwiftUI view bodies or per keystroke;
- revision-based index invalidation tests.

### Media matrix

The core knowledge layer does not open media. When Phase 2 adds playable media
evidence, reuse the standard mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, and avi/dv
matrix to verify citations and playback offsets without modifying source media.

### Isolation

- poison UserDefaults, profile storage, GEDCOM roots, and real catalog paths;
- inject filesystem, clock, and loaders;
- reject traversal, symlinks, sibling-prefix paths, oversized files, and
  corrupted JSON;
- prove tests never read or alter Rick's real family data;
- prove private items never pass a lower privacy ceiling.

### Production sensor

A synthetic end-to-end sensor must exercise:

```text
load -> validate -> identity bridge -> retrieve -> AnswerPlan -> prose/citations
```

It must prove that a contradictory or unsupported claim cannot appear in the
answer and that a one-item correction invalidates the old index generation.

## 15. Success criteria

CyberBrain succeeds when:

- Rick can correct any family assertion without retraining a model;
- every factual sentence can answer "how do we know that?";
- Hallie distinguishes fact, memory, inference, uncertainty, and disagreement;
- a nickname resolves consistently across GEDCOM, biographies, and media;
- multi-turn questions retain the intended person and evidence;
- the data remains readable and useful without VideoScan or Qwen;
- replacing the language model does not change the underlying family truth.

## 16. Decisions requested before Phase 1 code

1. Confirm **CyberBrain** as the UI/product name and
   `Breen Family CyberBrain` as the default archive display name.
2. Approve the proposed private/family/public privacy levels.
3. Decide whether a manually curated People-profile note may be imported as
   `probable`, or must always enter as `uncertain` pending review.
4. Approve a persisted UUID migration for People profiles.
5. Choose whether initial authoring is JSON/Markdown-only or includes a small
   in-app editor in Phase 1.

All other Phase 1 work can remain additive and read-only until these decisions
are settled.
