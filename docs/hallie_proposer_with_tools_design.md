# Hallie — from parser to proposer-with-tools

*Design, 2026-08-26. Rev 2 (same evening) incorporates codex's review #701. Status: PROPOSED — Rick reviews before any code. Author: Claude (Manager). Reviewer: codex.*

## 1. Why

On 2026-08-26 Rick spot-tested Hallie against the first 20-generation FamilySearch tree (16,383 people). Every miss was fixed the same way: another regex route in Swift ("trace … from ‹name›", "great great grandpa on his paternal side", "rick's grandma Muriel", superlatives, year bounds, great×N…). It worked — 64 % → most questions answered — but the pile is growing and getting stranger, and Rick called it:

> in the long run it will be a better architecture if we use a more powerful tool than continue to encode more and stranger rules … leverage the power of models and use the right tools.

The local model (qwen3.6 35B-A3B on Ollama today; bigger as unified RAM grows) already *knows* most of what those regexes encode. What it lacks is a contract that lets the app trust it. This document defines that contract so the model's role can grow **without the app changing shape** and **without giving up verifiability** — the 2026-08-14 decision (deterministic facts, LLM phrases) stays; the model gets to do the *reasoning*, not just the parsing.

## 2. Two kinds of rules (keep one, retire the other)

| Kind | Examples | Fate |
|---|---|---|
| **Parsing rules** | `HallieLineageQuestion.detect` regexes, `ArchivistQuestionParser.kinship`, `HallieKinshipApposition`, superlative shapes | Temporary. Retire per category when the model path beats them on the eval harness. |
| **Guard rules** | no photograph before 1839 (`WorldKnowledge`), Mc/Mac/O' fusing, first sentence names the subject, "me" = owner FamilySearch ID, never open with a bare surname, no keyword search on a superlative | Permanent. They are the contract with the family, not the intelligence. |

A new parsing regex after this date must carry a `// TEMPORARY: retire when eval category X passes via proposer` comment.

## 3. The contract: claims with citations

Today: `text → QueryAST (model) → deterministic executor → AnswerPlan → phrase (model) → verify (Swift)`.

Target: the model becomes a **proposer with tools**.

```
user text
  └─► Proposer (local model, tool-calling)
         tools: familyGraph.*, cyberBrain.*, worldKnowledge.*, catalog.*, people.*
         output: AnswerProposal { claims: [Claim], prose: String, actions: [OfferedAction] }
               Claim = TYPED payload, never free text (rev 2, codex S1):
                 birthDate(personID, value) · deathDate(personID, value) · place(personID, event, value)
                 relationship(subjectID, relation, objectID, pathIDs) · catalogCount(queryID, count)
                 mediaFor(personID, recordIDs) · mediumFeasibility(personID, medium, premiseIDs)
                 inference(kind, premiseClaimIDs, text)   — the only free-text kind
               Every payload references exact tool-result IDs the verifier can re-fetch.
               Model PROSE may cite only validated claim IDs; Swift generates the canonical
               factual sentence for each validated claim (AnswerPlan), so prose never
               carries a fact the plan doesn't.
  └─► Verifier (Swift, deterministic, pure)
         for each claim: re-derive from the cited source
           verified    → keep, spoken as fact, [cN]
           unverifiable→ DROP (rev 2, codex S2 — a hedge on a false fact is still a false fact)
           contradicted→ drop + log
           inference   → allowed only if proposed AS inference, every premise claim verified,
                         the inference kind is on the permitted list, and it can never drive
                         an action, a suppression, or a write
         guard rules run here (photography floor, name-first, bare-surname, …)
  └─► Composer (existing plan→phrase→verify; prose already proposed, so phrase step is optional)
```

Invariants (all testable without a model):
1. **No unverified fact reaches speech.** A `fact` claim with no verifiable citation is dropped, never softened.
2. **Every citation is re-derivable.** `Citation.ref` is a GEDCOM pointer, CyberBrain item id, WorldFact id, or catalog record id — never free text.
3. **Tools are read-only.** Writes (told-me, captions, pronunciations) stay on the existing telling routes with explicit confirmation.
3b. **Conversational truth ≠ operational authority** (rev 2, codex S3). The model may *say* a photograph was unlikely; only a deterministic tri-state policy over reviewed facts (`MediumFeasibility.assess → impossible | possible | unknown`) may veto an offer, a search, or a mutation. `unknown` never vetoes. (The 79-year lifespan heuristic that shipped on 08-26 was exactly this confusion; fixed same night.)
4. **Deterministic fallback.** If the proposer times out or returns malformed output, the current executor answers (today's behaviour), and the eval logs a `proposer-miss`.
5. **Same contract at every model size.** Nothing in the app depends on which model is behind Ollama; only the eval numbers do.

## 4. Knowledge tiers (where facts live)

| Tier | Owner | Store | Mutability | Cited as |
|---|---|---|---|---|
| World | shipped, versioned | a data resource (JSON in the bundle, not a Swift enum table — rev 2, codex S5/nit): `WorldFact{id, milestone, statement, earliest, latest, precision, sources:[{locator, version}], spokenClause}`; distinct milestones (first photograph of a person ≠ public photography; first film ≠ public cinema); a range is *dating uncertainty*, the **earliest** year is the only value a veto may use | never at runtime | `world:<id>@<version>` |
| Family | Rick / family | CyberBrain (`cyberbrain.json`: people, aliases, pronunciations, passages, captions, sources) | attributed writes | `brain:<itemID>` |
| Tree | FamilySearch | GEDCOM in `40_Family_Tree/GEDCOM` (newest valid wins) | re-pull | `gedcom:<@I..@>` |
| Catalog | VideoScan | catalog records, transcripts, tags | scans/jobs | `catalog:<recordID>` |
| Heuristics | engineering | `Heuristics` registry (proposed): `{name, default, rationale, overrideKey}` | settings | not cited; logged |

Rule: **no inline domain heuristics** — a date, a lifespan, a family-name particle in a chip builder is a bug. (Rev 2 scope, codex nit: UI/layout/perf constants are not domain knowledge and stay where they are; Mc/Mac/O' fusing is deterministic canonicalization, not world knowledge.)

The model may *mine* candidate world facts at authoring time; a human reviews; survivors go into the resource with a source locator. A local model does not look anything up — it recalls weights — so (rev 2, codex S4) model-weight answers are labeled **unverified**, never auto-promoted, and cited open-world answers require either the curated resource or a separately opt-in research provider. The existing `generalKnowledge` lane (no archive context, no citations) is the thing this replaces.

## 5. Tool surface (v1)

Small, typed, read-only, each returning citable refs:

- `familyGraph.person(id|name)`, `.relatives(id, relation, side)`, `.ancestorLine(id, line, generations, untilYear)`, `.descentPath(from,to)`, `.superlative(kind, scope)`, `.search(namedLike)`
- `cyberBrain.items(for personID)`, `.aliases(personID)`, `.resolve(name)`
- `worldKnowledge.fact(id)`, `.canHavePhotograph(personID)`
- `catalog.mediaFor(personID, years?)`, `.search(keywords)`, `.record(id)`
- `people.profile(name)`

Everything the regex routes compute today is reachable through these; the routes become thin wrappers and can be deleted one by one.

## 6. Verification depth

- **Facts** (dates, relations, places, counts): re-derived exactly from the cited source; mismatch = drop.
- **Inferences** ("probably named after her grandmother"): allowed only as `inference`, spoken with "I think" / "it looks like", never as fact; must cite the facts it rests on.
- **Opinions** (Hallie's warmth): no citations required; verifier only checks guard rules.
- **Optional critic pass** (cheap): after composition, ask the model "anything implausible?" — logged, never a veto.

## 7. Control: the eval harness decides

`scripts/hallie_eval.py` is the arbiter. Each question category (kinship, lineage, superlative, biography, media-by-person, small talk, telling) gets two lanes: `regex` and `proposer`. A category's regex route is retired when `proposer ≥ regex` on accuracy **and** `unverified-fact == 0` over the golden set — necessary, not sufficient (rev 2, codex): also report repeated-run variance (3 runs), schema-valid and tool-choice rates, p50/p95 latency, timeout/fallback rate, adversarial-injection outcomes, privacy isolation, and cost at 100k catalog records. Deterministic fast paths that are materially faster or more reliable are *kept*; deleting regexes is not the goal, trustworthy answers are. Today's live utterances (2026-08-25/26) are the first golden cases (codex #696 item 7).

## 8. Phases

0. **Contract + fixtures** (no model): `AnswerProposal`/`Claim`/`Citation` types; verifier over hand-written proposals against the synthetic 5-generation fixture; guard rules moved behind the verifier. Tests only.
1. **Proposer behind a flag**: `hallie.proposer.enabled` (default off). Tool-calling via Ollama's tool API (or a JSON-schema prompt if the model's tool support is weak); timeout → deterministic fallback. Eval lane added.
2. **Shadow mode**: proposer runs alongside the regex path in the eval harness only; report per-category deltas nightly.
3. **Category cutover**: flip categories by the §7 rule; delete the regex route in the same commit.
4. **Bigger box**: nothing changes but the model name and the numbers.

## 8b. Bounded orchestration (rev 2, codex)

- Typed capability registry: the proposer sees only registered tools with schemas; Swift owns every `OfferedAction`.
- Budgets: max tool turns, max tool calls, max result bytes per call, one end-to-end deadline; cancellation propagates to Ollama and to tool tasks.
- Deterministic fallback on any budget breach, timeout, or schema failure; the eval logs the reason.
- Endpoint policy: local/private hosts only (fleet list), never a public endpoint by default.
- Tool results are **data, not instructions**: prompt-injection treatment (delimited, labeled, never executed), tested adversarially.
- Cache key = evidence hashes + graph/brain/world/prompt/schema/model versions; a stale key is a miss, never a wrong answer.

## 9. Non-goals

- Fine-tuning a family model (CyberBrain §2 already argues why not).
- Letting the model write to any store.
- Removing the deterministic executor: it is the fallback forever.

## 10. Open questions for Rick

0. *(codex, answered 2026-08-26)* Measurement authorized: 30+ questions, M4 or M5, native tools vs constrained JSON, 3 runs — branch `test/qwen-tool-reliability`.

1. Tool-calling transport: Ollama native tools vs. constrained JSON — we should measure qwen3.6's tool reliability first (codex task).
2. Should `inference` claims be spoken at all in family-facing mode, or only in Rick's dev mode?
3. Heuristics registry: worth doing now (small) or after phase 1?
