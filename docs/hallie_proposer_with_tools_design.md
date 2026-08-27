# Hallie — from parser to proposer-with-tools

*Design, 2026-08-26. Status: PROPOSED — Rick reviews before any code. Author: Claude (Manager). Reviewer: codex.*

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
               Claim { id, text, citations: [Citation], kind: fact|inference|opinion }
               Citation { source: gedcom|cyberBrain|world|catalog, ref: String }
  └─► Verifier (Swift, deterministic, pure)
         for each claim: re-derive from the cited source
           verified   → keep, spoken as fact, [cN]
           unverifiable→ downgrade to "I think …" (kind = inference) or drop (kind = fact)
           contradicted→ drop + log
         guard rules run here (photography floor, name-first, bare-surname, …)
  └─► Composer (existing plan→phrase→verify; prose already proposed, so phrase step is optional)
```

Invariants (all testable without a model):
1. **No unverified fact reaches speech.** A `fact` claim with no verifiable citation is dropped, never softened.
2. **Every citation is re-derivable.** `Citation.ref` is a GEDCOM pointer, CyberBrain item id, WorldFact id, or catalog record id — never free text.
3. **Tools are read-only.** Writes (told-me, captions, pronunciations) stay on the existing telling routes with explicit confirmation.
4. **Deterministic fallback.** If the proposer times out or returns malformed output, the current executor answers (today's behaviour), and the eval logs a `proposer-miss`.
5. **Same contract at every model size.** Nothing in the app depends on which model is behind Ollama; only the eval numbers do.

## 4. Knowledge tiers (where facts live)

| Tier | Owner | Store | Mutability | Cited as |
|---|---|---|---|---|
| World | shipped | `VideoScanCore/WorldKnowledge.swift` (`WorldFact{id,statement,years,source,spokenClause}`) | never at runtime | `world:<id>` |
| Family | Rick / family | CyberBrain (`cyberbrain.json`: people, aliases, pronunciations, passages, captions, sources) | attributed writes | `brain:<itemID>` |
| Tree | FamilySearch | GEDCOM in `40_Family_Tree/GEDCOM` (newest valid wins) | re-pull | `gedcom:<@I..@>` |
| Catalog | VideoScan | catalog records, transcripts, tags | scans/jobs | `catalog:<recordID>` |
| Heuristics | engineering | `Heuristics` registry (proposed): `{name, default, rationale, overrideKey}` | settings | not cited; logged |

Rule: **no inline heuristics**. A number or a date in a chip builder is a bug.

The model may *mine* world facts at authoring time ("list dated facts about recorded media relevant to a family archive, with sources"); a human reviews; survivors go into `WorldKnowledge`. The model never decides a world fact at runtime.

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

`scripts/hallie_eval.py` is the arbiter. Each question category (kinship, lineage, superlative, biography, media-by-person, small talk, telling) gets two lanes: `regex` and `proposer`. A category's regex route is retired when `proposer ≥ regex` on accuracy **and** the proposer's `unverified-fact` count is 0 for that category over the golden set. Numbers, not vibes. Today's live utterances (2026-08-25/26) are the first golden cases (codex #696 item 7).

## 8. Phases

0. **Contract + fixtures** (no model): `AnswerProposal`/`Claim`/`Citation` types; verifier over hand-written proposals against the synthetic 5-generation fixture; guard rules moved behind the verifier. Tests only.
1. **Proposer behind a flag**: `hallie.proposer.enabled` (default off). Tool-calling via Ollama's tool API (or a JSON-schema prompt if the model's tool support is weak); timeout → deterministic fallback. Eval lane added.
2. **Shadow mode**: proposer runs alongside the regex path in the eval harness only; report per-category deltas nightly.
3. **Category cutover**: flip categories by the §7 rule; delete the regex route in the same commit.
4. **Bigger box**: nothing changes but the model name and the numbers.

## 9. Non-goals

- Fine-tuning a family model (CyberBrain §2 already argues why not).
- Letting the model write to any store.
- Removing the deterministic executor: it is the fallback forever.

## 10. Open questions for Rick

1. Tool-calling transport: Ollama native tools vs. constrained JSON — we should measure qwen3.6's tool reliability first (codex task).
2. Should `inference` claims be spoken at all in family-facing mode, or only in Rick's dev mode?
3. Heuristics registry: worth doing now (small) or after phase 1?
