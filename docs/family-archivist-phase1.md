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

## Architecture (knowledge-in-data; model is the voice)

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
        local LLM composes the ANSWER CONTRACT:
        prose + playable clip citations + basis line
        "I don't have evidence for that" is a first-class answer.
```

Rules (from #261/#263): the LLM never asserts a family fact it did not
retrieve; every answer carries citations; human tags are authoritative;
machine scores appear only with their tier+score label; no-evidence
questions must decline.

## The model question (Rick's qwen-ricks-family-32b)

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
4. **Answer composer** honoring the answer contract.
5. **Gold harness hook** — codex's 25 Rick-authored gold questions run
   as the acceptance gate; "Successful Queries" becomes the metric.

## Non-goals (Phase 1)

Family knowledge graph schema beyond POIProfile fields (Phase 2, with
Rick); mutation of any catalog state; remote/family-member access
(Phase 3 after ACL design); voice input; any model fine-tuning.
