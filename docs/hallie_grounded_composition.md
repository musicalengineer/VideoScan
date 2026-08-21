# Hallie grounded composition — plan → phrase → verify

Status: IMPLEMENTED 2026-08-17 (branch `feature/hallie-grounded-composition`)

Director intent (Rick, 2026-08-17): "make the archivist much more interactive"
— Hallie should answer in her own warm, plain voice about *this* family, like
talking to a person, **without ever asserting anything that is not in the
approved answer plan**. This is the "optional renderer" foreseen in
`docs/cyberbrain_design.md` §4/§9: the model may phrase; it is never the
authority for a family fact.

## 1. Pipeline

```text
user text ──► translate ──► execute (deterministic, unchanged)
                                   │
                                   ▼
                        HallieTurnExecutor.Result
                          prose (template) + basisLine + citations
                          answerPlan? (presence lists, CyberBrain bios)
                                   │
                    HallieAnswerPlan.derive(from:)      ← Swift only
                                   │
                    isComposable? ──no──► show template (composedBy: template)
                                   │yes
                    HallieGroundedComposer.compose      ← ONE local-model call
                          system prompt (persona + hard rules)
                          user prompt   (claims [c1..cN], counts, last ≤3 turns)
                                   │  ≤ 6 s, else template
                    HallieCompositionVerifier.verify    ← deterministic leash
                          keep sentence iff tagged with known claim IDs
                          and no leaked year / number / name
                                   │
                    ≥1 sentence kept? ──no──► template
                                   │yes
                    Result.applying(outcome)
                          prose = display text (tags stripped)
                          transcriptText = tagged text (log only)
                          composedBy = model
                          basisLine / citations / chips UNCHANGED
```

Translate → execute is exactly as before. Composition happens after the
deterministic answer is complete and never delays it past the budget.

## 2. HallieAnswerPlan (the contract)

`VideoScan/VideoScan/HallieAnswerPlan.swift`

| field | meaning |
|---|---|
| `route` | the executor route |
| `shape` | `list` (≤3 sentences), `biography` (≤6), `fact` (≤3), `fixed` (never composed) |
| `subject` | person/topic when there is one |
| `claims[]` | `id` ("c1"…), `text`, `evidenceIDs` (record UUID / GEDCOM pointer / CyberBrain evidence ID) |
| `counts[]` | labelled numbers the composer may quote (also folded into a claim) |
| `fallbackText` | the route's templated prose; shown whenever the model is off/slow/down/wrong |

Where plans come from:

- **presence / cross** (`HallieTurnExecutor+Presence.swift`):
  `HallieAnswerPlan.presenceList` — c1 = the templated count sentence
  verbatim (including paging / refinement wording); c2… = one claim per
  cited item, bounded to `maxItemClaims` (10): "Item k: filename [at Ns] —
  basis summaries". Counts: matching total, items listed.
- **CyberBrain biography** (`HallieTurnExecutor.swift`):
  `HallieAnswerPlan.biography(CyberBrainAnswerPlan)` — the approved
  `CyberBrainAnswerPlan.claims` verbatim (evidence IDs preserved) followed
  by the uncertainty statements as their own claims. Counts: supporting
  sources.
- **graph (GEDCOM kinship/birth/death/familyTree), temporal, aggregate**:
  `HallieAnswerPlan.derive` splits the templated prose into sentences, one
  claim per sentence. The composer can only re-say what the template said.
- **fixed** (never composed): help, capability, small talk, reset,
  follow-up media actions and declines, unsupported-event, every
  `declined` / `unsupported` / `needsClarification` outcome, and any result
  carrying a clarification.

## 3. Prompt (what the model receives — and nothing else)

System prompt (`HallieGroundedComposer.systemPrompt(personaName:)`), persona
name from `archivist.name` (default "Hallie Mae"):

> You are `<name>`, the family archivist. Warm, brief, plain words, no
> flourish; you are talking to an older reader who wants a straight answer.
> You are given an approved list of numbered claims about this family and a
> short recent conversation. Phrase those claims in your own voice.
>
> HARD RULES: Use ONLY the given claims. Never add a date, name, place,
> number, relationship, or event that is not in a claim. Every sentence must
> end with the claim IDs it rests on, in square brackets, like [c1] or
> [c2][c3]. A sentence with no tag will be discarded. Do not mention the IDs
> any other way. If the claims say there is no evidence, say so plainly.
> Keep it short: at most 3 sentences for a list of items, at most 6 for a
> biography. Plain text only.

User prompt (`userPrompt(plan:history:)`): the last ≤3 turns as
`User:` / `You:` lines (user text + displayed answer text only), `Subject:`,
`Answer shape:` (+ a list hint: items are shown below, name at most two),
`Numbers:`, then `[c1] …` claims, then "Write the answer now…".

Transport: `OllamaQueryTranslator.composePlainText(system:user:)` — same
host/model/envelope/error classes as translation, no JSON schema,
`temperature 0.3`, `num_predict 320`; walked over the fleet by
`OllamaFailoverTranslator.composePlainText` with the same probe/failover
policy. The archive is never sent; only the plan.

## 4. Verifier rules (`HallieCompositionVerifier`)

Sentence splitting: `.`/`!`/`?` followed by whitespace, a tag, a closing
quote, or end of text (so `12.5s` and `donna_cape.mov` survive), or a line
break. Tags immediately after the terminator belong to that sentence
(`"… born in 1920. [c1]"`). Tag forms accepted: `[c1]`, `[c1][c2]`,
`[c1, c2]`.

Per sentence, in order:

1. **untagged** — no claim tag → dropped.
2. **unknownClaimID** — any tag not in the plan → dropped.
3. **fact leak** against the tokens of *that sentence's cited claims* (plus
   the persona name), lowercased, possessives folded:
   - **leakedYear** — a 4-digit run absent from the cited claims;
   - **leakedNumber** — any other digit run, or a spelled-out number
     ("seven"; "one" exempt as a pronoun) with neither word nor digit in the
     cited claims;
   - **leakedName** — a capitalized word that is not sentence-initial, not
     `I`/`I'm`/…, and absent from the cited claims.
   Month abbreviations in claims vouch for the full month name and vice
   versa (`12 MAR 1920` ↔ `March 12, 1920`).
4. **overSentenceBudget** — beyond `plan.maxSentences`.

If nothing survives → `fallbackText`. Display strips the tags; the transcript
log keeps them.

Known strictness (by design, loosen only with Rick): a count *derived* from a
list ("two children" from "children as Rick, Mary") is dropped as a leaked
number; place names or relatives that appear only in another claim than the
one cited are dropped.

## 5. Latency / robustness

- Budget: 6 s wall clock for the whole phrasing step
  (`HallieGroundedComposer.timeoutSeconds`); the model task is cancelled and
  the template shown. Model error, empty reply, garbage, all-dropped → template.
- The coordinator/shell only call the composer for composable plans; fixed
  routes never pay a probe.
- No new dependency; same Ollama transport as translation.

## 6. Settings

- `archivist.composeWithModel` (UserDefaults) — default **ON** in the app;
  toggle in Settings → Archivist Brain: "Let Hallie phrase answers in her own
  words (facts stay locked)". `HallieCompositionSettings`.
- Shell: **OFF** unless `--compose`.
- Persona: `archivist.name` (blank → "Hallie Mae"). No hard-coded name in
  the composer prompt.

## 7. Result and log fields

`HallieTurnExecutor.Result` gained `answerPlan: HallieAnswerPlan?`,
`composedBy: HallieComposedBy` (`template` | `model`) and
`transcriptText: String?` (tagged text when the model wrote it).
`Result.applying(_:)` swaps only prose/provenance; basis line, citations,
chips, media actions are untouched.

`HallieTranscriptEvent` gained optional `composedBy` ("template" | "model");
for model-phrased answers `text` is the **tagged** sentence list so every
logged sentence traces to a plan claim; `basisLine` is the deterministic one.
Shell prints `phrased by: model (facts verified against the plan)` after the
prose; app log line: `Hallie: phrased <route>/<outcome> by <model|template>
(<note>; dropped N)`. Verifier drops are logged under the
`HallieComposer` os_log category.

## 8. Tests

`VideoScanTests/HallieGroundedCompositionTests.swift` (no network): plan
extraction per route; fixed routes/declines/clarifications never composable;
verifier matrix (untagged, unknown ID, leaked year/number/name, cross-claim
name, month expansion, spelled numbers, budget, tag variants, splitter);
fake composer (perfect / hallucinated extra sentence / empty / garbage /
error / timeout); prompt contents + persona swap + history bound; setting
default; coordinator seam (phrases composable answers, keeps basis and
citations; setting OFF → template; fixed routes never call the composer —
sensor; slow composer never blocks); shell `--compose` parse, output, tagged
transcript. Golden contract: displayed ⊆ verified and every displayed
sentence maps to claims — wording is never pinned.

`HallieGroundedCompositionLiveSmokeTests.swift` — opt-in
(`TEST_RUNNER_HALLIE_COMPOSE_SMOKE=1`), local Ollama on 127.0.0.1, prints
outputs, asserts only the contract.
