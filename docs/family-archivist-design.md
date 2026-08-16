# Family Archivist — NL search frontend design

Status: **ACTIVE — rapid dev on main** (Rick + Claude pairing; codex = tests/review/quality).
Started 2026-08-01. Owner: Rick (director). Implementation: Claude. QA/testing: codex.

## Vision (Rick, 2026-08-01)

The catalog is the most-used, most-loved surface in VideoScan; POI person-search has
underdelivered. Build a natural-language frontend so Rick — and eventually less-technical
family, possibly via a future web interface — can talk to the archive:

- "show me videos of Donna from 1992 to 1995"
- "how many videos do we have from the 90s?"
- "clips where someone says happy birthday"

End state: conversing with an **expert family archivist** who knows where every
interesting video is, asks refining questions ("you mean down the cape, or in the 90s?"),
and over time answers deeper family questions — eventually including ancestors from
FamilySearch.org. The main function is SEARCH; everything else is staged on top.

## Architecture — the anti-hallucination contract

```
user sentence
   │  (already looks like infix? → skip the brain entirely)
   ▼
translator brain (local LLM)          ← emits NLQuerySpec ONLY (fixed JSON schema)
   ▼
NLQueryNormalizer  (fail-closed)      ← whitelists, clamps, strips grammar chars
   ▼
NLQueryComposer → existing infix string ("people:donna year:1992..1995 type:video")
   ▼
pfTokenizeSearchQuery / CatalogSearchIndex   ← the SAME path as a hand-typed query
   ▼
Swift computes results/counts; replies are deterministic templates
```

Load-bearing invariants (each has a pinning test — break one, and a test must fail):

1. **The brain never sees catalog content and never phrases facts.** It converts a
   sentence to a spec. Swift computes truth. A bad translation is a visibly-wrong,
   editable FILTER — never a confidently-wrong FACT.
2. **Values are data, not syntax.** Colons/quotes are stripped by the normalizer; only
   the composer may quote. No spec value can mint a field token. Pinned by
   `composedStringsTokenizeWithoutStructureLeaks` + `fieldSyntaxInValuesIsNeutralized`
   (round-trips through the real tokenizer).
3. **Fail closed.** The production translator rejects unknown wire fields,
   enum values, types, and oversized lists independently of Ollama's schema;
   unsafe values from other in-process callers are still dropped by the
   normalizer as defense in depth. Insane years → dropped. Empty spec →
   literal substring search of the raw text. Brain unreachable/thrown → same
   literal fallback, honest status in UI.
4. **Every applied query is visible and editable** — it lands in the catalog's real
   search field ("Interpreted as" transparency).

## What is on main (P0 + P1, commits 7200341 + 6249702)

| Piece | File |
|---|---|
| Wire schema + normalizer + composer | `VideoScan/VideoScan/NLQuery.swift` |
| Translator seam + ollama brain | `VideoScan/VideoScan/OllamaQueryTranslator.swift` |
| Deterministic tests (8) + live eval | `VideoScan/VideoScanTests/NLQueryTests.swift` |
| Golden corpus (15 cases) | `tests/search_nl_cases.json` |
| Persisted audition results | `tools/search-eval/eval-*.json` |
| 100k search bench (pre-existing) | `VideoScan/VideoScanTests/CatalogSearchProfileBench.swift` |

Brain details: ollama native `/api/chat`, `think:false` (reasoning models otherwise burn
the whole token budget — same bug fixed in tools/jim, af7c116), `format:` = JSON schema
of NLQuerySpec (model is constrained to the wire format), temperature 0. Transport is
pluggable: URLSession in production (triggers the one-time macOS Local Network prompt);
curl-via-ProcessRunner in tests (headless test hosts have no Local Network TCC grant —
URLSession → `.local` silently TIMES OUT there; this cost us a 0/15 eval run before
diagnosis).

First audition (persisted `tools/search-eval/eval-2026-08-01T16-30-27Z.json`):
**qwen3.6:35b-a3b-nvfp4 @ ricksm5 — 13/15 strict** (bar: 10/15). Both misses were
defensible readings; the interesting one: "anything down the cape with the boys" →
`people:boys` — semantically right, but `people:` only matches tagged NAMES, so keyword
recall wins. Prompt-tuning lesson: `people:` requires a name.

Live eval: `TEST_RUNNER_NL_EVAL=1 xcodebuild test -only-testing:VideoScanTests/NLTranslatorLiveEvalTests`
— grades people/years/mediaKind/intent strictly, keywords leniently; writes a dated
report under `tools/search-eval/`. Never runs in CI; the default suite is LLM-free.

## P2 (next, being built RD on main): the Archivist window

- New `Window("Family Archivist", id: "archivist")` scene + Window-menu item + catalog
  toolbar button. State in `ArchivistSession` (@MainActor ObservableObject): transcript,
  current query, brain status.
- **Catalog binding:** applying a query writes the composed infix into the catalog's
  REAL search field (published request on DashboardState → ContentView applies to its
  `@SceneStorage` searchText), switches to the Catalog tab, raises the main window.
  The search box visibly "types itself" — transparency + editability + grammar teaching.
- Per-message flow: infix-looking input applies instantly (no LLM); otherwise
  thinking → translate → normalize → apply; empty → literal fallback with honest
  phrasing. `count` intent applies the filter AND answers the number.
- Replies: deterministic Swift templates + computed counts. No LLM phrasing in v1.
- v1 is fresh-search-per-message. Refinement/carry-over context + agent-initiated
  clarifying questions are P4.

## Later phases

- **P3**: aggregates ("how many per decade") — grouped counts computed in Swift.
- **P4**: conversational context (refine previous query), clarifying questions.
- **FoundationModels audition**: on-device brain behind the same NLQueryTranslating
  seam (@Generable guided generation, macOS 26-gated), graded on the same corpus.
- **Web reuse**: translator is a pure String→spec function — the future family web
  interface reuses it behind HTTP.

## Standing asks for codex

1. **Review P1** (commits 7200341, 6249702): NLQuery.swift normalizer edge cases,
   OllamaQueryTranslator error paths, the curl transport (shell-arg safety of
   `--data-binary` with attacker-influenced text), test quality.
2. **Adversarial corpus expansion**: grow `tests/search_nl_cases.json` — injection
   variants, homoglyph/unicode tricks, absurd year phrasings ("the summer before Timmy
   was born"), multi-person + negation ("without Donna" — we currently have NO negation;
   should translate to keywords or be documented as unsupported).
3. **Five-dimension coverage** as P2 lands: scale (search side is benched; translator is
   O(1)), isolation (ArchivistSession must not poison real prefs), media matrix (n/a),
   sensors (structure-leak sensor exists — extend as grammar grows).
4. **Watch main**: we are rapid-dev'ing P2 on main in small commits. Post-merge review
   sweeps welcome — file findings to the channel or as GH issues tagged to #123/#150-style
   follow-up issues.
5. **Eval rigor**: critique the grading (strict fields vs lenient keywords), suggest
   corpus size / stratification before we trust a brain swap.
```
