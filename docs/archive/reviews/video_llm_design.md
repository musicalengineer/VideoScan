# Video LLM design: review notes for the Fri/Sat deep dive

*Claude, 2026-10-29. Notes on `docs/design/video_llm_lab_2026_10_30.md` (the design) and
`docs/research/video_llm_for_family_media_2026-10-29.md` (the research note), both written by Claude Code web
sessions on 10/29. Overwrite this file as the review moves on; do not add a second one.*

## The design in five sentences

1. A video model watches sampled frames and listens to the transcript, and writes down what it sees as small
   typed claims ("looks like 1991–95, because: 4:3, VHS tracking lines, boxy sedan"), each with the frames it used.
2. It is a witness, never the judge: claims go into a lab notebook first, and only reach the catalog after the model
   has passed a test, and even then Rick confirms.
3. "Try a model, then try the next" is built in: swap the frame picker, the model, or the prompt; each run is scored
   against answers we already have (73 dates Rick entered, 5,635 camera-dated files, 18 confirmed events, 1,448
   on-screen dates).
4. Everything runs on our Macs; no family pixels or audio leave the house.
5. "Expert on the Breen media" means the facts live in the catalog and the family tree, the model is shown Rick's
   confirmed examples when it works, and Hallie answers from that with citations. The model's weights never hold
   family facts.

## Verdict

Good, and grounded in what the app already has. It agrees with the rulings and with Claude's own read of the Gemini
documents (local only; no Neo4j/Qdrant/MinIO; no training on facts; keep the structured JSON and the "same room
across decades" idea).

## Things to settle in the deep dive (in order)

1. **It does not yet fit the background service.** The design makes model analysis an in-app job you start
   ("Analyze with Model…"). We agreed on 10/29 that this kind of work should run in a background service that keeps
   going after quit. Content Analysis already has a Scene Captions job, so as written there would be two captioning
   engines (rule 4: one engine per action). Proposal: one engine, shared by Content Analysis and the model lab, hosted
   by the background service.
2. **18 events is a small test.** A pass mark like "8 of 10 right" measured on 18 events can swing a lot by luck.
   The date/era test rests on far more data (73 + 200 dated files) and is the more trustworthy first test.
3. **Small fixes:** the research note says the provenance table goes in schema v13; v13 is already Set Role, so it is
   v14 (the design is right). The design doc lives at `docs/` top level; design docs go in `docs/design/`.
4. **Rick's four rulings** (design §9), one at a time: cloud for derived text only (captions/transcripts, never
   pixels) or local only · one hour labelling 50 places · Qwen or Gemma first on the Ultra · when schema v14 lands.

## First step when research mode starts

Phase 0: wrap today's 3B captioner as the baseline, publish its scores against the answers we already hold. No schema
change, no rulings needed, none of Rick's time. Every later model is compared to that number.

## Related, parked

- Background service needs (10/29 conversation): what may run after quit; one supervisor; visible and stoppable with
  the app closed; journals only, the app applies them; its own name in Activity Monitor; backs off when Rick works.
- Provenance Grade (auto-generated, per file): #396; BACKLOG line "Catalog right-click Provenance ▸ …". Model assertions from this design would feed it.
