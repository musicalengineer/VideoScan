# Hallie spot-test misses — 2026-08-28 evening (Rick, main 20f18bae, 16k single-source tree loaded)

Ordered by demo impact. Fix after dinner; each gets a corpus line in tests/hallie_live_misses_corpus.json (no regexes — see proposer direction).

1. **"closest common ancestor of rick and donna" → "Donna Hudson is Richard Harding Breen Jr's wife."** The direct-relation shortcut (spouse edge) preempts an explicit common-ancestor ask. Rule: when the question names the shape (common ancestor / related by blood / how far back), run `.commonAncestor` even if a direct edge exists; mention the marriage as an aside. Also: the loaded tree was the single-source 16k one (codec-3 generation refused after codec 4) — Donna had no ancestors; ingest rerun fixes the data side.
2. **"me (Rick)" → "Which rick do you mean?"** with candidates like Catherine Auker (b. 1374). Speaker/owner pin must bind "me"/"I"/"(Rick)" before any name search; and the graph-route name matcher for a bare given name on a 16k–39k tree is far too loose (offers non-Richards). Constrain: exact/diminutive on GIVEN name only, prefer roots/POI-bridged people, cap candidates, else say so. Known lowercase echo ("rick") too.
3. **"the one born in 1959"** as a which-one reply → translator decline. Clarification replies by birth year/date/place should select the matching candidate.
4. **"you presented me a list of people born hundreds or years ago"** → catalog search for "hundreds of years ago" → declined. Conversation-repair / meta turns must not become searches; acknowledge and re-offer a better which-one.
5. Positive: "can you find richard breen jr family tree?" → parents, spouse, 10,136 ancestors / 19 generations from the compiled artifact — good.

Also: Family Tree navigation has no timing logs (load → layout → focus); add >100 ms lines.

## 8/29 morning (main 9e27c40b)
6. **"can you center on marhta lamson"** → catalog search (fixed 9e27c40b: `.centerTree` shape, auto-performed action, spelling recovery stated).
7. **"tell me about Matthew Rice"** → "born 28 February 1629, died before 29 November 1717; child of Edmund Rice and Thomasine Frost." — no places, no marriage (Martha Lamson), no children, while "…the family tree on martha lamson" gave parents + marriage + children + depth. Biography must be ONE consistent card: vitals with places, parents, marriages (with dates), children, tree-depth summary, all cited.

## Feature idea (Rick 8/29 11:45) — "Research Person"
Right-click tree person → Research: FSID-keyed pane under People/<FSID>/research/; sources: FamilySearch record hints, Find a Grave, Chronicling America (LoC newspapers), Wikipedia/Wikidata, web search constrained by dates/places; LLM summary with per-sentence citations; findings marked confirmed/plausible/wrong + lore → CyberBrain attestations Hallie cites. Deceased/tree people only (privacy). Design doc after kinship lands.

## Feature idea (Rick 8/29 11:50) — remote use from another Mac; eventually a web portal
Today: Hallie web server (port 8765) serves chat + playback to iPad/browser. Direction: catalog/tree/Hallie READ for any authorized family member via the web portal (already the privacy model: read for all, write = Rick); full-app remote (another Mac) = later; design with the identity/attestation foundation first.
8. **(8/29 13:05)** With the compiled generation refused after the codec bump (needsRecompile), "find our nearest common ancestor" → "I don't have an imported family tree, so I can't answer that reliably." — false: the tree is on disk, it needs a recompile. Hallie must distinguish no-tree from needs-recompile, say so, and offer/perform Recompile (auto-performed action like centerTree).
9. **"find our nearest common ancestor"** — "our" = owner + the person in conversation focus (Donna, just discussed) or owner + spouse. Verify after recompile; add to the detector if it misses.
