# Research Person — a sourced dossier per tree person, told to Hallie

**Status:** PROPOSED 2026-08-29; Phase 1 in progress (Rick asked "is it in play?" at 17:20). Priority after remote-use in Rick's list, built in parallel. Reviewer: codex.

Rick (8/29): "I click a person in the tree, like David T McGill → right-click → Research Person. This starts a research process… an internet search for records of the person from that time, say 1875… occupation, stories in the news, etc. Links to Hallie so we can work together to 'tell' Hallie about things we may have in the family lore or bible."

## Principles
- Keyed by FamilySearch ID (uuid fallback), never raw @I pointers; stored under `People/<FSID>/research/` (survives re-pulls).
- Deceased / tree people only. Contemporary People-tab profiles never go to the internet (privacy).
- Findings are evidence, not facts: each has source, URL, retrieved date, excerpt, and Rick's verdict (unreviewed / confirmed / plausible / wrong) + free-text lore. Confirmed → CyberBrain attestation Hallie can cite ("Berkshire County Eagle, 12 May 1875 — confirmed by Rick").
- LLM only summarizes fetched text with per-sentence citations; the verifier drops uncited sentences (existing composition discipline).

## Phase 1 (now)
1. Context menu on tree cards: **Research Person…** → Research pane (right side / sheet) for that FSID: header (name, vitals from the tree), query plan shown (name variants, years, places), "Run" button.
2. Sources, free and unauthenticated: Chronicling America (LoC) full-text newspaper search API (1770–1963) constrained by name + years + state; Find a Grave search (HTML, polite, cached); Wikipedia/Wikidata lookup; general web search (DuckDuckGo HTML or SearchKit-free approach; respect robots; ≤ N requests; cached on disk with retrieved date). All network work off-main, cancellable, logged as counts.
3. Findings list: source badge, title, date, excerpt, link; verdict buttons; lore text field; "Tell Hallie" writes confirmed items as CyberBrain attestations (existing CyberBrainWriter / `--remember` path) with the citation.
4. Hallie: "what do we know about David McGill from research" → cites confirmed findings; unconfirmed never cited.
5. Tests: query-plan builder (name variants incl. maiden/alternate names, year window ± tolerance, place tokens), source adapters against recorded fixtures (no live network in tests), verdict persistence + isolation, CyberBrain attestation shape, privacy guard (contemporary profile → refused), scale (100 findings render O(1)).

## Later
LLM summary paragraph with citations; FamilySearch record hints when the API is un-parked; Ancestry/FamilySearch images with login; batch research for a whole line.
