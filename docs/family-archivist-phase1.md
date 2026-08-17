# Family Archivist — Phase 1 design (read-only vertical slice)

*2026-08-05. Rick = product director & domain oracle; Claude = architect/
implementer; codex = QA/design challenger (charter: channel #262/#263).
Goal: **ask any question about someone in the catalog.***

## Scope of this slice

Read-only. No mutation, no web exposure, no new privacy surface.
Extends the existing P0/P1 NL stack (NLQuerySpec → normalizer →
catalog search) from 2 intents to the six validated query shapes:

| Shape | Example | Answered from |
|---|---|---|
| presence | "Donna at Christmas in the 90s" | tags + dates (exists) |
| temporal | "how old was Timmy here?" | file date − POIProfile.birthdate |
| aggregate | "who appears most with Donna?" | tag co-occurrence |
| event | "what happened at Matt's 1st birthday?" | transcripts + captions |
| graph | "who is Ellen?" | POIProfile fields + family graph |
| cross | "where Dan opens the red bike" | transcript/caption search |

## Architecture (knowledge-in-data; model is the translator)

**Decision — 2026-08-14, Rick:** factual prose is composed
deterministically in Swift. The LLM translates the user's words into a
strict QueryAST only; it never sees retrieved family evidence and never
phrases a factual answer. This resolves the earlier draft conflict in favor
of the original anti-hallucination contract in
`docs/family-archivist-design.md`.

```
chat pane ──► local LLM (qwen via ollama, existing translator path)
                 │  emits TYPED QueryAST (never free-form SQL/answers)
                 ▼
        PersonResolver ── aliases/nicknames → canonical POI identity
                 ▼
        deterministic executors (search_catalog · get_person ·
        co_occurrence · transcript_search — pure Swift, unit-tested)
                 ▼
        EvidenceSet with PROVENANCE LABELS
        (human tag > machine tier(score) > transcript mention > caption)
                 ▼
        deterministic Swift composes the ANSWER CONTRACT:
        prose + playable clip citations + basis line
        "I don't have evidence for that" is a first-class answer.
```

Rules (from #261/#263 and Rick's 2026-08-14 decision): the LLM never
receives retrieved evidence or asserts a family fact; every factual answer
is a deterministic function of a validated QueryAST and cited EvidenceSet;
human tags are authoritative; machine scores appear only with their
tier+score label; no-evidence questions must decline.

## The model question (Rick's qwen-ricks-family-32b)

The post-Phase-1 family knowledge layer is now specified in
[`cyberbrain_design.md`](cyberbrain_design.md). **CyberBrain** is the durable,
source-aware Breen family memory; the model remains its replaceable language
interface.

Facts live in DATA (graph + catalog + dossiers) — updatable, citable,
and portable to 2060; the LLM is a swappable voice. A literal
`qwen-ricks-family-32b` artifact stays on the roadmap as a DISTILLATION
of this system (synthesize QA pairs from verified graph facts → LoRA)
once the graph exists — the system generates its own training data.
Persona/terminology LoRA ("the boys", "Nana's house") is a cheap later
polish. No family-facts fine-tune before the graph exists.

## Phase 1 deliverables

1. **QueryAST v2** — typed, six shapes, JSON-decodable from the LLM
   translator with strict validation (unknown fields/values rejected,
   never guessed).
2. **PersonResolver** — name/alias/nickname → canonical POI identity
   (case/diacritic-insensitive; ambiguity is surfaced, not guessed —
   "Tim vs Timmy" asks, doesn't assume; both exist as separate POIs).
3. **Executors** for presence + temporal + aggregate (graph/event/cross
   land in Phase 1.5 once codex's acceptance criteria are in).
4. **Deterministic Swift answer composer** honoring the answer contract;
   no LLM factual-prose pass.
5. **Gold harness hook** — codex's 25 Rick-authored gold questions run
   as the acceptance gate; "Successful Queries" becomes the metric.

## Headless access and biography portraits (2026-08-14)

`scripts/hallie` starts an interactive, read-only Hallie Mae shell from a
built VideoScan executable. The `--hallie` route exits before the SwiftUI app
entry, decodes the catalog without constructing `CatalogStore`, uses QueryAST
v2, and opens media only after an explicit shell command. `--once` supports
non-interactive use. Its exit status is 0 only for a factual answer (2 =
catalog unavailable, 3 = no evidence/source, 4 = unsupported QueryAST shape,
5 = translation failure), and the responder is labeled as the interpreter,
not the factual answerer. The event shape declines until it has a
deterministic executor; it is never coerced into a broader search. Cross
(person AND spoken/visible terms) runs on the presence executor since
2026-08-17, with both bases cited per item.

## Conversation memory and model-free turns (2026-08-17)

Rick's demo to Donna showed five "normal human" phrasings failing. All five
now resolve deterministically BEFORE any translation, in a step shared by
the app coordinator and the shell (`HallieTurnExecutor.preTranslation` +
`ConversationMemory`, resolver in `ArchivistFollowUpResolver`):

1. Follow-ups on the last answer — "play one of them, say the first one",
   "reveal number 3", "the one from 1994", "show more"/"the rest" (paging
   by citation offset), and elliptical refinements ("and in the 90s?",
   "what about matt?") that edit the previous validated AST field by field
   ("refining your last question" in the basis line). No prior answer →
   an honest "Ask me for something first".
2. Family tree — `graph.familyTree` (person / surname / whole tree) with an
   offered "Open in Family Tree" action; the sentence shapes are also
   recognised locally.
3. Multi-hop kinship with side — closed vocabulary up to great-great,
   aunts/uncles, cousins, nieces/nephews, basic in-laws; the answer lists
   the route per relative and names the exact missing hop.
4. Cross-evidence and age phrases — "as a baby / kid / teenager" becomes a
   year band from a vouched birth year (profile → CyberBrain → GEDCOM),
   cited in the basis line.
5. Capability questions — "can we change donna's biography?" and other
   edit/remember/learn or media-mutation requests get an honest, model-free
   answer with an offered next step.

Golden corpus: `tests/archivist_golden_answers.json` v3 (`conversationCases`).

Biography answers may attach the uniquely matched POI cover photo. The photo
is presentation, not family-fact evidence: its path or bytes are never sent to
the translator, and missing, ambiguous, non-image, traversal, or symlink cover
references are omitted. The app renders the portrait inline; the shell prints
its local path and requires `:open-photo` or `:reveal-photo` before invoking
AppKit. App rendering uses a bounded ImageIO thumbnail decoded off-main rather
than loading a full-resolution phone or scan image on the main actor.

## Non-goals (Phase 1)

Family knowledge graph schema beyond POIProfile fields (Phase 2, with
Rick); mutation of any catalog state; remote/family-member access
(Phase 3 after ACL design); voice input; any model fine-tuning.
