# Hallie E1 — does a cloud agent loop beat today's Hallie?

*Harness spec, 2026-10-10. Status: PROPOSED. Python only; no app change. Companion to [hallie_agent_lane_2026_10_10.md](hallie_agent_lane_2026_10_10.md) (the Swift design) and §R6 of [hallie_proposer_with_tools_design.md](hallie_proposer_with_tools_design.md) (Rick's ruling). Author: Claude (design agent). Reviewer: Rick, then in-house `qa`; no codex pass (no data-loss path — spend policy).*

## 1. The question, and what "wins" means

**Hypothesis.** A frontier model running a bounded tool loop over the *same* read-only tools answers the 775-question corpus better than today's deterministic chain + local translator — and does it without ever speaking an unverified fact or answering about the wrong person.

**Why a Python harness first.** The Swift agent lane is ~2 weeks of work (client, loop, verifier, UI). E1 answers the go/no-go question in ~3 days for tens of dollars: if the loop does not clearly beat today's lane on the existing corpus, we have learned that cheaply and the rev-5 local shape stays the plan.

**"Wins" (recommendation; Rick decides — agent-lane doc §12, D10).** On the strict lane (67 rows) and the full corpus (775 rows), the agent lane must show *all* of:

| Metric | Threshold |
|---|---|
| Flag-free rate (existing `grade_record`) | ≥ today's lane + 10 points on strict, ≥ +5 on the full corpus |
| Unverified-fact count | **0** (any claim the verifier dropped counts, even if the prose was true) |
| Wrong-subject count | **0** (an answer whose `subjectIDs` miss a person the question named and resolved) |
| Decline-correctness | ≥ today's lane (graceful_decline rows declined AND answerable rows answered) |
| p95 latency | ≤ 20 s per turn (the app's deadline) |
| $ per full run | measured; the number itself is not a gate, the budget cap is (§8) |

A win on accuracy with any unverified fact or wrong-subject answer is **not a win** — those two are the systemic defect this whole program exists to remove.

## 2. What E1 measures, and what it does not

E1 measures the **control loop**: can the model pick the right tools, read results, chain calls, and submit a cited, typed answer or an honest decline? It does **not** benchmark the Swift engines. The Python tools in §4 are thinner than their Swift counterparts (no typo front door, no kin-term rebind ladder, simpler relationship wording). Where the Python tool is weaker than Swift, the agent lane is handicapped, not flattered — the comparison is conservative in the direction we want. Where a Python tool would need Swift-only logic to be honest (identity resolution of a bare kin word, for example), the tool returns `{"ok": false, "error": "needs-app-resolver"}` and the row is tagged `tool_gap` in the report so it is not scored as a model failure.

## 3. Snapshots (read-only export)

One command exports four snapshots into a dated folder **outside the repo**:

```
~/Library/Application Support/VideoScan/hallie-e1/snapshots/2026-10-11/
  manifest.json          # created, source paths, sha256 + record counts per file, redaction report
  tree.ged               # a byte copy of the GEDCOM the app currently promotes
  catalog.json           # the app's catalog file, copied
  people/<uuid>.json     # one file per People-tab profile (POI/<uuid>/profile.json)
  cyberbrain.json        # the CyberBrain archive
```

| Snapshot | Source (read, never written) | Notes |
|---|---|---|
| Tree | the GEDCOM the app promotes: `FamilyGraphFileLoader` rules (promoted compiled generation first, else newest valid `.ged` under `40_Family_Tree/GEDCOM`; `VideoScan/VideoScan/FamilyTree/FamilyGraphFileLoader.swift:45-70`) | The harness has no Swift, so `scripts/hallie_e1_export.py` reproduces rule 4 only (newest valid non-empty `.ged` by mtime) and **prints the chosen path**; Rick confirms it matches the app's Family Tree tab once. Parsed by a minimal level-based GEDCOM reader (INDI, FAM, NAME, SEX, BIRT/DEAT + DATE/PLAC, FAMS/FAMC, NOTE, `_FSFTID`/REFN for the FamilySearch id). ~150 lines, tested on the synthetic 5-generation fixture. |
| Catalog | `~/Library/Application Support/VideoScan/catalog.json` (`CatalogStore.swift:568-571`; a `CatalogSnapshot {version: 6, generation, savedAt, records: [VideoRecord]}`) | Only the fields the tools read are loaded: `id`, `filename`, `fullPath`, `durationSeconds`, `dateCreated`/`userDate`/`inferredRecordDate`, `confirmedByUserPeople[{name, confirmedAt}]`, `tags`, `userNotes`, `userPlace`. `audioTranscript` and `sceneCaptions[].text` are loaded only with `--include-derived-text` (default off — Rick's open question; §6); without it the tool still reports *that* a transcript or caption exists so `evidence.kind` can be `transcript`/`caption` with no words. |
| People | `~/Library/Application Support/VideoScan/POI/<uuid>/profile.json` | name, aliases, kinships, treeIdentity pin, notInFamilyTree, birth/death dates. The inner circle and living status come from here (§6). |
| CyberBrain | `~/Library/Application Support/VideoScan/cyberbrain/cyberbrain.json` | Items with `privacy`, `status`, `subjectPersonIDs`, `sourceIDs`. The tool applies the privacy ceiling (`family` for E1; `private` items never leave the snapshot). |

Export rules: copy, never move; refuse symlinks; refuse to write inside the repo (`manifest.json` records `repo_relative: false` and the test asserts it); `.gitignore` already excludes Application Support, and the snapshot folder is additionally checked by `tests/test_hallie_e1.py::test_snapshot_dir_is_outside_repo`.

**Redaction at export.** The export drops any field whose name matches `embedding|faceprint|thumbnail|frame|preview|data:` and writes what it dropped into `manifest.json.redaction`. This is belt-and-braces: the tools never read those fields, but a snapshot that cannot contain `familyMedia` bytes cannot leak them.

## 4. Tools over the snapshots

The tool **names, descriptions and JSON Schemas are the same file the Swift lane will use**: `docs/hallie_tools.schema.json` (generated by the Swift catalog in phase 0; hand-written for E1 and diffed against the Swift output when phase 0 lands — the golden test is listed in the agent-lane doc §13). The harness loads the schema file and binds each name to a Python callable:

```python
TOOLS: dict[str, ToolImpl] = {
    "resolve_person":       resolve_person,        # people/ + tree + cyberbrain names → candidates with ids
    "person_facts":         person_facts,          # tree.ged INDI + People-tab dates
    "relatives":            relatives,             # FAMC/FAMS walk; side = maternal/paternal via parents' sex
    "relationship_between": relationship_between,  # BFS over parent/child/spouse edges, depth 12; direct-line depth 25
    "ancestor_line":        ancestor_line,         # climb one line N generations
    "tree_people_where":    tree_people_where,     # filter: bornIn/diedIn/bornBetween/surname/scope; list|count
    "tree_superlative":     tree_superlative,      # earliestBorn/latestBorn/longestLived… over a scope
    "family_knowledge":     family_knowledge,      # cyberbrain items for a person, privacy ≤ ceiling, ≤ 12
    "search_media":         search_media,          # catalog records by people/keywords/years; evidence kinds
    "catalog_stats":        catalog_stats,         # total/years/longest/shortest/newest/oldest
    "world_fact":           world_fact,            # the bundled WorldFact JSON (photography floor etc.)
    "submit_answer":        None,                  # terminal: handled by the loop, not a data tool
}
```

Every data tool returns the rev-5 envelope, now with a data class:

```json
{"ok": true, "items": [...], "ids": ["gedcom:@I13@", "people:7F2C…", "brain:item.42", "catalog:5E1A…"],
 "truncated": false, "queryID": "q-3f9a", "dataClass": "familyText",
 "subjects": [{"id": "gedcom:@I13@", "living": false, "immediateFamily": false}]}
```

`ids` is the only thing a claim may cite. Result size is capped at the tool's budget (agent-lane doc §4); `truncated: true` is explicit so the model can narrow rather than guess. Place matching in `tree_people_where` uses a gazetteer built from the GEDCOM place strings plus a short alias table (Scotland ⊂ UK, "Mass." = Massachusetts), as the 10/09 compound-queries design specifies; an unknown place is `ok:false, error:"unknown-place"`.

**Fidelity notes (tagged `tool_gap`, not scored as failures):** bare kin words ("my dad", "dad breen") resolve only through People-tab kinship rows — the Swift `SpeakerKinship.rebind` ladder is richer; relationship wording is "N-th great-grandfather / first cousin twice removed" from path shape, not `GedcomRelationshipPath.describe`; no typo front door — the model is told typos are the asker's and names are never corrected.

## 5. The agent loop (Anthropic Python SDK)

Manual loop, not the SDK tool runner: we need a per-turn deadline, a call/byte budget, request/response recording for the dry-run cassettes, and usage accounting per iteration — control the runner does not expose. The shape is the documented manual loop (`messages.create` → `stop_reason == "tool_use"` → execute → `tool_result` blocks in ONE user message → repeat).

```python
def run_turn(client, model, question, history, tools, budget) -> TurnRecord:
    messages = history + [{"role": "user", "content": question}]
    calls, tool_calls, t0 = 0, 0, time.monotonic()
    while True:
        if time.monotonic() - t0 > budget.deadline_s or calls >= budget.max_model_calls:
            return TurnRecord.fallback("budget", ...)
        resp = client.messages.create(
            model=model, max_tokens=4096,
            system=SYSTEM_BLOCKS,                       # last block carries cache_control
            tools=tools,                               # strict schemas, deterministic order
            messages=messages,
            cache_control={"type": "ephemeral"},       # automatic breakpoint on the growing tail
            output_config={"effort": budget.effort},   # per model row; see matrix
        )
        calls += 1; usage.add(resp.usage)
        if resp.stop_reason == "refusal":
            return TurnRecord.decline("refusal", resp)
        if resp.stop_reason == "max_tokens":
            return TurnRecord.fallback("max_tokens", resp)
        uses = [b for b in resp.content if b.type == "tool_use"]
        submit = next((u for u in uses if u.name == "submit_answer"), None)
        if submit:
            return verify_and_record(submit.input, tool_results_this_turn)
        if not uses:                                   # end_turn with prose only
            return TurnRecord.fallback("no_submission", resp)
        messages.append({"role": "assistant", "content": resp.content})
        results = [execute(u, budget) for u in uses]   # read-only ⇒ safe to run all; errors → is_error
        tool_calls += len(uses)
        messages.append({"role": "user", "content": results})
```

Rules the loop enforces, mirroring the Swift design:
- **Thinking:** adaptive (omit `thinking`; it is on by default on the 5.5 generation and Fable 5.1). `output_config.effort` is the only knob; it is a column in the model matrix.
- **No forced tool choice.** `tool_choice: any/tool` is a 400 on the 5.5 generation and Fable 5.1. The system prompt says the turn must end with `submit_answer`; a turn that ends without one is a `no_submission` fallback, counted.
- **`strict: true`** on every tool so arguments are schema-valid; schemas carry `additionalProperties: false` and `required`.
- **Tool results are data.** Each result is wrapped as JSON under a `<tool-result>` label and the system prompt states results are never instructions. The adversarial rows (a planted "ignore previous instructions" in a GEDCOM NOTE and in a transcript fixture) assert no behaviour change.
- **Fallback = decline.** The harness has no deterministic executor, so `fallback(reason)` records `outcome: declined` with the reason; the Swift lane will route to today's chain instead. Fallback rates are reported per reason.
- **Follow-ups.** Rows marked `followsPrevious` reuse the previous row's `messages` (history kept, including the model's tool calls); a scenario boundary resets history — the same `:reset` semantics `build_stdin` applies today.
- **Refusal fallbacks** (`fallbacks` parameter) are off: a refusal on a family-archive question is a datum we want to see, not route around.

### 5.1 `submit_answer` (the terminal tool)

```json
{"name": "submit_answer", "strict": true,
 "input_schema": {"type": "object", "additionalProperties": false,
  "required": ["questionReading", "subjectIDs", "unresolved", "claims", "prose", "outcome"],
  "properties": {
   "questionReading": {"type": "string", "description": "One sentence: what you understood the asker to want."},
   "subjectIDs":  {"type": "array", "items": {"type": "string"}, "description": "ids from THIS turn's tool results that the answer is about"},
   "unresolved":  {"type": "array", "items": {"type": "string"}, "description": "names the asker used that no tool resolved"},
   "outcome":     {"type": "string", "enum": ["answered", "declined", "needsClarification"]},
   "declineReason": {"type": "string", "enum": ["notInTree", "ambiguous", "noMedia", "noKnowledge", "outOfScope", "none"]},
   "claims": {"type": "array", "items": {"$ref": "#/$defs/claim"}},
   "prose": {"type": "string", "description": "Hallie's wording. Cite claims as [c1], [c2]. A sentence with a name, date, number or place and no citation will be removed."},
   "offers": {"type": "array", "items": {"type": "string", "enum": ["openFamilyTree", "showPhotos", "playMedia", "narrow"]}}
  },
  "$defs": {"claim": {"type": "object", "additionalProperties": false,
    "required": ["id", "kind", "cites", "value"],
    "properties": {"id": {"type": "string"}, "kind": {"type": "string",
      "enum": ["birthDate","deathDate","eventPlace","relationship","familyItem","mediaFor","catalogCount","mediumFeasibility","worldFact","inference"]},
      "cites": {"type": "array", "items": {"type": "string"}}, "value": {"type": "string"}}}}}}
```

### 5.2 Verifier (Python port of the rev-5 table §3.1)

For each claim: the cited ids must have appeared in a tool result **this turn** (turn-local provenance — a fact about last turn's person cannot be spoken), and the value must re-derive from the snapshot (birth/death date exact incl. qualifier, place after normalisation, relationship path reproduced by the same BFS, catalog count re-run, CyberBrain item active and ≤ ceiling). Failed → dropped and counted as `unverified_fact`. Prose sentences citing only dropped claims are removed; an uncited sentence containing a name/date/number/place is removed (today's `HallieCompositionVerifier` rule). Then the **subject check**: every name in the question that `resolve_person` resolved this turn must be in `subjectIDs` or `unresolved`; a miss is `wrong_subject` and the turn is converted to a decline — the "Henry VIII → Philippa" class made structural.

## 6. Privacy in the harness

- **Data classes.** Every tool result carries `dataClass ∈ {public, familyText, familyMedia}` and `subjects[{living, immediateFamily}]`. The single function that turns a result into a `tool_result` content block — `remote_serialize(result)` — is the enforcement point: `familyMedia` items are replaced by their ids and kinds; nothing else is sent. There is exactly one caller.
- **What counts as `familyMedia` here.** Pixels, audio, frames, embeddings (never in the snapshot — §3 redaction) **and, by default, transcript and caption text** (Rick's open question; default stays local). `--include-derived-text` flips the class to `familyText` for the run and the report header says so in red.
- **Living immediate family.** From the People tab: a profile with a kinship row to the owner (or the owner) and no death date → `immediateFamily: true, living: true`. Unknown death date on anyone born after 1926 → `living: true` (conservative). These flags ride on every result's `subjects` so the Swift lane and the report can key on them.
- **Sensor.** `test_remote_serializer_never_emits_family_media`: a fixture catalog with a canary transcript string and a canary caption; run the scripted agent across the strict rows; assert the canary never appears in any recorded request body, AND assert that with `--include-derived-text` it does (the test proves the gate, not an absence of data).
- **Key handling.** `ANTHROPIC_API_KEY` if set; else the macOS Keychain item `security find-generic-password -s hallie-e1 -a anthropic -w` (stored once by Rick with `security add-generic-password`); else the SDK's own credential resolution (`ant auth login` profile). The key is passed to `anthropic.Anthropic(api_key=...)` in memory only; the run meta records `keySource: "env"|"keychain"|"profile"` and nothing else about it. Never in git, never in a log, never in the report.

## 7. Scoring — side by side with today's lane

The harness writes records in the **same jsonl shape `hallie_eval.py` writes** (`build_records` fields: `id, category, expect, expectedRoutes, mustContain, mustNotContain, mustMatch, answer, route, outcome, queryDescription, basis, mediaEvidence, knowledgeEvidence, composedBy, model`) plus E1-only fields (`lane: "agent"`, `toolCalls, modelCalls, unverifiedFacts, wrongSubject, fallbackReason, latencyMs, usage{input, cacheWrite, cacheRead, output}, costUSD`). Grading imports `grade_record` from `scripts/hallie_eval.py` via `importlib.util.spec_from_file_location` (the pattern `hallie_eval.py` itself uses for `watch_hallie_chat`), so **nothing is re-implemented and nothing in the grader changes**. `route` is mapped from the tools used (`graph` when tree tools dominated, `presence` for `search_media`, `catalog-stats`, `social`), so `expectedRoutes` rows grade the same way.

The baseline is a run file from today's lane: `python3 scripts/hallie_eval.py run …` on the same corpus the same night (or the latest nightly `~/Library/Logs/VideoScan/hallie-eval/…/advisory.graded.jsonl`). `hallie_e1.py report --agent <run> --baseline <run>` joins by `id` and prints per-category: flag-free %, Δ, unverified facts, wrong-subject, decline-correctness, p50/p95 ms, $.

Metric definitions:
- **Accuracy** = rows with no flags (flags starting `~` are informational and excluded, as today).
- **Unverified-fact count** = claims dropped by the verifier, summed; also reported as rows-with-any.
- **Decline-correctness** = (graceful_decline rows that declined + answerable rows that did not decline) / rows; also the two halves separately (the `answered_unknowable` and `declined_expected_answer` flags already encode them).
- **Wrong-subject** = §5.2 subject-check failures (an E1-only metric today's lane cannot report; for the baseline it is approximated by `forbidden_text` on rows whose `mustNotContain` names a person).
- **Latency** = wall clock from the first request to the verified record, per turn; p50/p95 per category and overall; tool execution time reported separately so model time is visible.
- **$ per run** = Σ over calls of `usage.input_tokens × in + cache_creation_input_tokens × in × 1.25 + cache_read_input_tokens × cacheRead + output_tokens × out`, with the price table in `scripts/hallie_e1_prices.json` (dated; the report prints the table it used).
- **Variance** = three seeds on the strict lane for the winning model before any decision (rev-4 rule); the report shows min/median/max.

## 8. Model matrix and cost estimate

Prices (Anthropic first-party, cached in the `claude-api` reference 2026-10-06; re-check before paying):

| Model | id | input $/M | output $/M | cache read $/M | cache write $/M (1.25×) |
|---|---|---|---|---|---|
| Haiku 5.5 | `claude-haiku-5-5` | 0.10 | 0.50 | 0.01 | 0.125 |
| Sonnet 5.5 | `claude-sonnet-5-5` | 2.00 | 10.00 | 0.20 | 2.50 |
| Opus 5.5 | `claude-opus-5-5` | 4.00 | 20.00 | 0.20 | 5.00 |
| Fable 5.1 | `claude-fable-5-1` | 10.00 | 50.00 | 0.25 | 12.50 |

**Per-turn token model (assumptions, to be replaced by measured `usage`):**
- Stable prefix (system prompt + 12 tool schemas): ~3,500 tokens. Written once per run per model, read on every call (minimum cacheable prefix is 512 tokens on these models, so it caches).
- Model calls per turn: ~3.5 (one plan, ~2 tool rounds, one submit). Tool rounds average ~2.5 tool calls, ~1,200 tokens of result each → ~3,000 tokens of tail that is written to cache once (automatic breakpoint) and read on later calls.
- Uncached input per turn: question + tail written ≈ 3,600 tokens (cache write) + ~200 fresh.
- Cache reads per turn: 3.5 calls × 3,500 prefix + tail re-reads ≈ 16,000 tokens.
- Output per turn: 3.5 calls × (~150 tool_use/text + ~350 thinking at medium effort) ≈ 1,750 tokens. Thinking is billed as output; `low` effort roughly halves it.

**Per-turn cost, medium effort:**

| Model | fresh in 200 | cache write 3,600 | cache read 16,000 | output 1,750 | **per turn** | **× 775** | **× 67 (strict)** |
|---|---|---|---|---|---|---|---|
| Haiku 5.5 | 0.00002 | 0.00045 | 0.00016 | 0.00088 | **$0.0015** | **$1.2** | $0.10 |
| Sonnet 5.5 | 0.0004 | 0.0090 | 0.0032 | 0.0175 | **$0.030** | **$23** | $2.0 |
| Opus 5.5 | 0.0008 | 0.0180 | 0.0032 | 0.0350 | **$0.057** | **$44** | $3.8 |
| Fable 5.1 | 0.0020 | 0.0450 | 0.0040 | 0.0875 | **$0.139** | **$107** | $9.3 |

Arithmetic example, Sonnet: 200×2.00/1e6 = 0.0004; 3,600×2.50/1e6 = 0.0090; 16,000×0.20/1e6 = 0.0032; 1,750×10/1e6 = 0.0175; sum 0.0301 × 775 = $23.3. The tokenizer on this generation runs up to ~1.35× some older counts, so treat every figure as ±35% until the first `usage` numbers land — the harness prints a `count_tokens` estimate of the prefix and refuses to start when the projected run exceeds `--budget-usd`.

**Recommended spend plan (~$70 total, D5):**
1. **Strict lane, all four models, one seed** — ≈ $15. Dry-run first (free), then Haiku, then Sonnet; Opus and Fable only if Sonnet shows headroom on the wrong-subject or lineage rows.
2. **Full corpus, best two models** — Sonnet + one other ≈ $25–70 depending on which. Fable 5.1 is **not** recommended on the full corpus (≈ $107) unless step 1 shows it alone clears the gate.
3. **Three seeds on the strict lane for the chosen model** — ≈ $6 (Sonnet).
4. Re-runs that only need cost/accuracy (not latency) can go through the Message Batches API at 50% price; latency rows must stay on the live endpoint.

Fleet: the harness runs on the M4 or M5 Pro (it is network-bound, not compute-bound) — never on the M4 brain while a Hallie replay is sharing it (the 09-25 lesson). Rick's Claude usage cap: E1 bills the API key, not the Claude Code plan; still record the spend in the report header, as the codex policy does.

## 9. Dry-run mode (works with no key, no network)

`--dry-run` substitutes a `FakeClient` with the same `messages.create(**kwargs)` surface. Two sources, in order:
1. **Cassettes.** `tests/fixtures/hallie_e1/cassettes/<model>/<row-id>/<n>.json` — recorded with `--record` on a real run; each file is the request hash + the response body. Replay matches on request hash; a mismatch (prompt drift) is reported, not silently answered. Cassettes contain tool results, so they are recorded **only from the synthetic fixture snapshot** (`tests/fixtures/hallie_e1/snapshot/`: the 5-generation synthetic tree, a 40-record synthetic catalog with one canary transcript, 6 synthetic profiles, a 10-item synthetic CyberBrain). Real-family cassettes never enter git (test: no cassette row id matches the live corpus' `lv*`/`fam*` ids with real names — the fixture corpus uses `e1-fixture-*` ids).
2. **Scripted fake.** With no cassette, the fake emits a deterministic tool plan derived from the row's `expectedRoutes`/`expect` (graph → `resolve_person` → `person_facts` → `submit_answer`; catalog → `resolve_person` → `search_media` → `submit_answer`; social → `submit_answer` only; graceful_decline → `resolve_person` → `submit_answer(outcome: declined)`), plus three deliberately bad scripts (an uncited fact, a fact about last turn's person, a hallucinated tool) so the verifier, subject check and error path are exercised offline.

`pytest tests/test_hallie_e1.py` runs entirely in dry-run: export (fixture snapshot → temp dir, redaction report), each tool against the fixture, the loop with the scripted fake, verifier drops, subject check, cost accounting against a frozen price table, the privacy sensor, record shape compatibility with `grade_record`, and the report join. CI-safe: no network, no key, no Application Support.

## 10. Files (to be created in the E1 PR; none exist today)

| Path | Purpose |
|---|---|
| `scripts/hallie_e1_export.py` | snapshot export + manifest + redaction |
| `scripts/hallie_e1.py` | `run`, `report`, `estimate` subcommands; `--model`, `--effort`, `--corpus`, `--limit`, `--seeds`, `--budget-usd`, `--dry-run`, `--record`, `--include-derived-text`, `--out` |
| `scripts/hallie_e1/tools.py`, `gedcom.py`, `verifier.py`, `loop.py`, `fake_client.py`, `costs.py` | the pieces above; pure functions where possible |
| `scripts/hallie_e1_prices.json` | dated price table |
| `docs/hallie_tools.schema.json` | tool schemas (shared with the Swift lane) |
| `tests/test_hallie_e1.py`, `tests/fixtures/hallie_e1/` | offline tests, synthetic snapshot, cassettes |
| `~/Library/Logs/VideoScan/hallie-eval/e1-<date>/` | run jsonl per model/seed, `report.md`, `costs.json` |

## 11. Report shape (what Rick reads in the morning)

```
E1 2026-10-12  corpus 775 (sha …)  baseline: nightly 2026-10-11 (qwen3.8:27b-mlx, ollama 0.34.4)
model            flag-free   Δ    unverified  wrong-subj  decline-ok   p50/p95 s   $/run   fallbacks
today's lane      71.4%      —        n/a        (≈3)       84%        2.1/9.8      $0      —
haiku-5-5  low    …
sonnet-5-5 med    …
per category: kinship / catalog / biography / social / graceful_decline / clarify / lineage …
tool_gap rows excluded: N (listed)
privacy: derived text EXCLUDED; familyMedia bytes sent: 0 (sensor green)
```

Both run files and the report go to the eval log folder; the design decision ("build phase 0 cloud-first, or not") is written into §R6 of the proposer doc with the report path.
