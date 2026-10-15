# Event Analyzer — "Compare Media"

**Status:** PROPOSED 2026-10-15 (Rick + Claude, from two mocks). No code yet. Builds on
`related_score_2026_10_14.md` (the ladder of evidence), `audio_fingerprint_2026_10_14.md`
(engine + overnight stamps, done), `footage_spectrum_design_2026-10-03.md` (Compare Footage,
kept as is), `events_design.md` (Triage ▸ Events v1, done). Serves goals 2 (recognize and
organize events) and 3 (remove excess) in `docs/project_goals.md`.

Mocks: Fingerprint Views https://claude.ai/artifact/6UxVePCiphb1doast2oXSk ·
Compare Media https://claude.ai/artifact/KH75sLkQPZ79jYcrDTXyse (private to Rick).

## 1. In Rick's words

"If I could wish for anything I'd wish for a magic tool to tell me 1. are these media files
representing the same event exactly in all ways 2. if different, how are these media files
different 3. or a bold statement: these media files do not represent the same event in any
way." And: "Like the AA and the CA, this is the Event Angel or Event Analyzer which uses all
the leverage of fingerprints, spectra, SHA, durations, metadata, captions, transcripts,
dates/times, etc., to assist the user in organizing, deleting, promoting, categorizing,
repairing, and identifying and grouping events … Once we associate events we can figure out
what to archive and what to delete."

Two files at a time, like holding two strips of film side by side. If two works, a third
comes as "compare against", swapping the right-hand spool, never a third spool.

## 2. The view: Compare Media (replaces the Catalog's "Compare these two files")

Top to bottom:

1. **The verdict band.** One word, one colour, the duration beside it:
   | Band | Colour | Means |
   |---|---|---|
   | SAME EVENT | medium green | identical copy, or the same recording in another transfer |
   | CLIP FROM SAME EVENT | light green | a clip of the other; "1:18 of 38:00 · at 6:16" |
   | SAME EVENT · DIFFERENT CAPTURE | yellow | two cameras / two tapes of one occasion |
   | DIFFERENT EVENTS | red | no rung of the ladder holds |
   | NOT ENOUGH EVIDENCE | grey | no fingerprint, silent, no full hash, drive offline |
2. **The headline and the evidence lines** under the band, from the ladder (rung,
   supporting lines, contradicting lines shown with a red dot, non-clues with a grey dot:
   "both say happy birthday — a word, not an event").
3. **The recommendation** (§4), one sentence, bold verb, with the "why" and the one
   button that does it.
4. **Two spools**, time running down on one shared axis, the clip's spool offset to sit
   beside the master's matching minutes, green ties between them across the matched
   stretch. Each spool: header facts (length, codecs, frame size, size, SHA-256, date,
   fingerprint, people, words, archive status) with every field that differs in the accent
   colour; then the filmstrip (§3) with the sound strip beside it (landmark density,
   matched stretch in green, silence grey).
5. **Folds**: Streams (today's Compare table), People seen, Words heard, Footage spectrum
   (today's Compare Footage, untouched, folded), The recommendations (the table in §4).

A slider sets frames per minute (10 s to 120 s a frame); scrolling down scrolls through
time on both spools together.

**Next face.** A button pair (and ↓ / ↑, with the mouse wheel for continuous scrolling)
jumps both spools to the next section where a face was found, on either spool, and names
the person when the People tab knows them. Rick: "the mouse wheel or a button will scroll
down the filmstrips to the next person's face." The jump keeps the two spools aligned on
the shared axis, so landing on Timmy at 19:40 in the master shows what the other camera
had at that moment. A pair with no faces on either side says so in the band ("no faces
found") rather than offering a dead button.

## 3. The filmstrip: significant frames, never leaders

Rick: "fast forward to a significant frame, avoiding leaders." For each section of the
spool (one per `interval` seconds) the frame shown is the first frame IN that section with
real picture, judged without decoding more than the preview cache already holds:

1. **a face first** (Rick: "a person's face is probably the most important thing to
   find"): if any sampled frame in the section has a detected face, the section shows the
   one with the largest face, and a confirmed person's name goes under it (the People tab's
   detector output is already cached per sampled frame; a section the cache has not seen
   is asked for at the slider's interval, off the main actor);
2. else **real picture**: luminance spread above a floor (not black, not white, not one
   colour) and edge content above a floor (a blurred blue leader, colour bars, a static
   title card and the VHS "PLAY" overlay all fail);
3. else the section's best-scoring frame, dimmed, so a dead stretch still reads as dead.

Frames are large enough to see the scene and who is in it (112 px wide in the mock; ~96 to
140 px in the app depending on the pane). The preview cache supplies them; the compare job
asks for the ones it lacks at the slider's interval, off the main actor, and the view fills
in as they arrive. Nothing here decodes video on the main actor.

## 4. The recommendations (eight rules; the verdict plus what the archive holds)

| Rule | When | It says | Where it goes |
|---|---|---|---|
| R1 | identical copy; the other is the archived master | Master is archived. Remove this copy. | Cleanup ▸ copies the archive holds |
| R2 | clip of an archived master | Master is archived. Remove the clip; cut a fresh one from the master when you want it. | Cleanup ▸ clips of a master (to build) |
| R3 | same recording, older or worse transfer; the archived one is better | Master is archived in the better transfer. Remove this transfer so the newest codec is what survives. | Cleanup ▸ superseded transfers (to build) |
| R4 | same recording and THIS one is better (longer, higher resolution, original codec) than the archived one | This transfer is better than the archived one. Promote it, then retire the old master. | Archive Angel ▸ Promote |
| R5 | same event, different capture | Keep both. Group them under one event; refile a misfiled one. | Events ▸ confirm / merge |
| R6 | same event, nothing archived yet | Nothing is archived. Promote the longest, best capture as the master, then revisit the clips. | Archive Angel ▸ Recommend |
| R7 | different events | Nothing to do. | — |
| R8 | not enough evidence | Fingerprint and hash these first; the analyzer can't say yet. | Catalog ▸ Fingerprint Sound… / Fill In Full Hashes… |

"Better" in R3/R4 is decided by a small ordered list, shown with the recommendation:
longer audible duration › original-generation codec (DV / ProRes from tape beats MPEG-2 /
H.264 re-encodes) › frame size › bit rate. Ties keep the archived one.

Every recommendation is advice. The button hands the pair to the lane that already proves
things at the move (Cleanup) or to the Angel; nothing on this view moves a file.

## 5. Where the evidence comes from (all of it exists today, or is designed)

| Line | Source | State |
|---|---|---|
| identical copy | whole-file SHA-256 (ContentFixity) | done |
| same recording / clip of / same moment | AudioFingerprintMatcher over the sidecar stamps (offset, coverage, distribution) | done (10/14 engine, 10/15 backfill) |
| frames align / no run in common | video barcode alignment (Compare Footage) for silent footage | done (Phase 1) |
| people seen | detectedPeople / confirmedByUserPeople with seconds | done |
| words heard | audioTranscript, sceneCaptions | done |
| dates, folders, tape labels | userDate / inferred date / folder label (EventLabeler) | done |
| archive status, better transfer | isArchiveFile, archivedCopy(of:), stream facts | done |
| the ladder → verdict word | RelatedScore (VideoScanCore, pure) | to build |
| the recommendation | EventRecommendation (pure, table-driven: rule × archive state) | to build |

## 6. Order of work

1. `RelatedScore` (pure, table-tested: every rung, every contradiction) and
   `EventRecommendation` (the eight rules) in VideoScanCore. Red tests first.
2. Compare Media view: verdict band + evidence + recommendation over the existing Compare
   job's inputs, with the two spools reading the preview cache and the fingerprint sidecar;
   the significant-frame rule as a pure scorer over cached frame statistics.
3. The folds: today's Streams table and Compare Footage, folded.
4. The three Cleanup lanes the recommendations point at that do not exist yet: clips of a
   master (R2), superseded transfers (R3), each safety-critical with codex, proving at the
   move exactly as the Copies lanes do.
5. Then the Events page gets the same verdict band and spools per suggested group (the
   "same occasion or different years?" question pre-answered), and the constellation.

## 7. Tests (five dimensions)

Logic: ladder truth table; recommendation table (rule × archive state × "better");
significant-frame scorer on synthetic black / bars / blue / face frames. Scale: a 100k
catalog, pair lookups O(1) by digest. Media matrix: the A/B/C/D/E fingerprint fixtures plus
leader-prefixed variants. Isolation: no sidecar / no fingerprint / no hash → "not enough
evidence", never a wrong word. Sensor: nothing in the view body decodes media or walks
records; the verdict and the frames come from caches and the one compare job.

## 8. Open questions for Rick (one at a time)

1. R3 removes an older transfer of a recording whose master is archived. The DVD's menu
   and chapters go with it. Fine, or keep DVD rips as a "second transfer" exception?
