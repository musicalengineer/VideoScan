# Hallie: compound questions, people filters, and counts (design, 2026-10-09)

**One sentence (Rick):** "Hallie should handle *tell me about X and Y*, *X or Y*, *find people
born in Scotland*, *count people born in Salem* — and keep getting better from my own questions."

Status: design; Rick approved the approach 2026-10-09 ("not a radically new version overnight").
Build after Bonnie's visit, about 2–3 nights, gated by the Hallie testbed. Codex design pass first.

## 1. Why she can't today (verified on main @ 007fc2c2a)
- `ArchivistQueryAST` (Hallie/ArchivistQueryAST.swift) is a closed, single-intent enum:
  `presence | temporal | aggregate | event | graph | cross | record`. One question → one intent,
  so "X **and** Y" loses half, and "X **or** Y" has no meaning.
- `graph` answers per-person questions (`birthPlace` of *one* person, relationships, lineage).
  There is no "people WHERE …" filter over the tree.
- Counts exist only as fixed tree statistics (`HallieTreeStatisticsQuestion`: count / lifespan /
  birthCountries over a scope), not "count people matching a filter".
- The translator (`OllamaQueryTranslator`, LLM → AST JSON) can only emit what the AST can hold.

## 2. New query shapes (additive to QueryAST v2 → v3; old JSON still decodes)
1. **compound** — `{"shape":"compound","payload":{"op":"and"|"or","parts":[<AST>, …]}}`
   - `and` between *topics* ("tell me about Ma and Dad") = answer each part, in order, one turn.
   - `and` between *people in a media search* ("videos with Ma and Dad") is NOT compound — it
     stays `presence` with both people (co-occurrence), as today. The translator prompt and an
     oracle test set must pin this distinction.
   - `or` = answer each part, labelled ("For Ma: … For Dad: …"); for media search, the union.
   - Max 4 parts; nested compound refused (decline politely).
2. **people** — `{"shape":"people","payload":{"filter":{…},"operation":"list"|"count"}}`
   - Filter fields (all optional, AND-ed): `bornIn` (place), `diedIn`, `bornBetween`
     (years), `diedBetween`, `surname`, `relatedTo` (a person + relation set, e.g.
     descendants of), `side` (maternal/paternal, existing `Side`).
   - **Place containment**: a place gazetteer built from the GEDCOM place strings
     ("Salem, Essex, Massachusetts, USA" → Salem ⊂ Essex ⊂ Massachusetts ⊂ USA; country names
     and common aliases: Scotland ⊂ UK, "Mass." = Massachusetts). "Born in Scotland" matches
     every place whose chain contains Scotland. Unknown place → say so ("I don't have a place
     called X in the tree"), never guess.
   - `count` answers with the number AND the names (up to N, then "and 12 more"), with
     sources (the tree records). `list` = names with years and birthplaces.

## 3. Execution stays deterministic and sourced
The model only translates; executors answer from the catalog / tree. The composer
(`HallieGroundedComposer`) phrases the result; the verifier (`HallieCompositionVerifier`)
checks every number and name in the reply appears in the result. A count the executor didn't
produce can't be said.

## 4. The improvement loop (overnight, on any Mac Rick picks)
1. **Harvest** weekly: new questions from the Hallie log (existing `hallie_harvest_queries.py`),
   deduplicated by shape.
2. **Vary**: for each shape, generate 10–20 paraphrases ("born in Scotland", "who came from
   Scotland", "how many of us were Scottish-born", "Scots in the family") — local model, then
   a human-free sanity filter (the expected AST is known from the template).
3. **Replay** (`scripts/nightly_hallie_replay.sh` — headless, read-only catalog, local Ollama),
   strict + advisory lanes as today.
4. **Cluster failures by shape**, not by question. A shape with < 90% pass becomes the next fix.
5. Every fixed shape adds its cases to the **strict** lane, so it can't regress.
Rick runs it on demand: "run the Hallie testbed on the M5" (ssh, results in the morning brief).

## 5. Later: a translator fine-tuned on Rick's own questions (MLX LoRA, local)
- Training data = (question → AST) pairs from §4: harvested + generated + corrected. **No
  family facts in the training set** — only phrasing and query shapes. Facts stay in the
  database, cited.
- A small local model (8–14B) with a LoRA adapter, trained with MLX on the M4 or the M5 Ultra;
  the testbed's strict lane is the acceptance gate (must beat the current translator on every
  shape, and never regress a strict case).
- Payoff: steadier and faster translation of Rick's phrasing; cheaper to run; the large model
  stays for composition only if needed.

## 6. Order of work
1. AST v3 types + decoding (old JSON unchanged) + oracle tests for `and` vs co-occurrence.
2. Place gazetteer from the GEDCOM (pure, tested on synthetic place strings) + `people`
   executor (list/count) + verifier coverage.
3. `compound` executor (sequence / union) + composer for multi-part answers.
4. Translator prompt + few-shot examples for the new shapes; replay; fix by shape.
5. Strict lane additions; then the variation generator.
6. (Ultra) LoRA translator experiment.

## 7. Open questions for Rick
- "Tell me about X or Y": answer both (labelled), or ask which? (Proposal: both.)
- Count answers: always list the names, or only on "who are they?" (Proposal: up to 10 names.)
- Living people in lists (privacy for the future web viewer): include, or only deceased +
  inner circle? (Proposal: follow the existing viewer-role rules when the web release comes.)
