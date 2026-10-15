# Related score — "how are these two recordings connected?"

**Status:** PROPOSED 2026-10-14 (Rick + Claude). No code yet. Follows
`audio_fingerprint_2026_10_14.md` (engine merged 2802f2197; overnight
backfill in flight), `events_design.md`, `footage_spectrum_design_2026-10-03.md`,
`find_original_design.md`. Serves goals 2 (recognize and organize events)
and 3 (remove excess) in `docs/project_goals.md`.

## 1. The question, in Rick's words

"Combine the audio fingerprints with everything else we have — metadata,
transcript, captions, video spectrum, duration, some video frame sampling —
to create a similarity or 'related event' score, shown to the user in a
creative way." And from the Events spot test: "same occasion / different
occasion has no compare … I thought audio fingerprint would show the %
similar or grade them."

## 2. Principle: a ladder of evidence, words first

Two recordings get ONE headline word, decided by the strongest evidence
that holds, plus every supporting and contradicting line underneath. Not a
weighted sum: a blended 0.73 cannot be explained, a ladder can (Angel
ruling: words, not grades; show the WHY).

| Rung | Headline | Evidence that puts a pair here | Source we hold today |
|---|---|---|---|
| 6 | **Identical copy** | same whole-file SHA-256, both current | ContentFixity |
| 5 | **Same recording** / **Clip of** | audio landmarks: coverage ≥ bar over non-silent seconds, one offset, distributed; or video barcode alignment for silent footage | AudioFingerprint (sidecar), Compare Footage strips |
| 4 | **Recorded at the same time** | a short audio run at one offset (two cameras overlapping; the same song playing in the room), durations and dates compatible | AudioFingerprint, dates |
| 3 | **Same occasion** | date within the Events window, same confirmed people, same names said (transcript), same scene words (captions / later SigLIP 2), same folder label; no reliable-date conflict | Events inputs, detectedPeople, audioTranscript, sceneCaptions, EventLabeler |
| 2 | **Related** | same people or place or season, different day | people, userPlace, dates |
| 1 | **No connection found** | nothing above holds | — |

Each rung has a CONTRADICTION rule that blocks it (a reliable date conflict
blocks 3 and 4; an audio verdict `.different` with both files audible and
overlapping in time blocks 4). Contradictions are shown, never silently
subtracted.

Numbers stay attached to the lines, not the headline: "shares 80 % of its
sound with X, from 6:16", "3 of 4 confirmed people in common", "names said
in both: Timmy, Donna".

## 3. Where it runs, and what it costs

- Pairwise ONLY inside an Events group (witnesses of one proposed occasion
  or the two sides of the "same occasion or different years?" question).
  Never catalog-wide O(n²). A group of 40 recordings is 780 pairs; audio
  matching is ~30 ms a pair once fingerprints exist.
- Scores are cached in a sidecar table keyed by (digestA, digestB, engine
  versions). Recomputed only when an input changes.
- Audio fingerprints come from the overnight backfill (sidecar
  `audio-fingerprints.sqlite`). Video strips come from Compare Footage's
  barcode when a file has no audio (video-only MXF halves, silent DV).
- Everything runs off the main actor as one MFO-shaped step inside the
  Events planner; the page reads cached values only.

## 4. The display ("creative, but readable")

1. **Spectra, aligned.** One strip per recording on a shared time axis
   (sound strip; video barcode under it when present). Matched stretches
   light up in one colour across strips; a clip sits inside the master where
   it belongs; an unmatched stretch stays grey. This is Rick's 10/3 spectrum
   idea, now with sound.
2. **The constellation.** The occasion's recordings as stars; a line between
   two when they reach rung 4 or above, thickness by coverage, colour by
   rung. Click a line → the evidence lines. (Rick is the town astronomer;
   this is his metaphor.)
3. **The grid.** A small pairwise matrix, darker where more is shared, for
   groups too big for a constellation to read.
4. **The question, pre-answered.** "Same occasion, or different years?"
   arrives with the machine's answer and the headline word; Rick confirms
   or overrides in one click. The machine goes first; the person decides.

## 5. Order of work

1. Tonight: fingerprints for every file (backfill).
2. Next: `RelatedScore` (VideoScanCore, pure, table-tested) over the inputs
   we already have: SHA-256, audio match, dates, people, transcript names,
   folder labels. The Events detail sheet shows the aligned sound strips,
   the grid and the pre-answered question.
3. Then: video barcode for silent footage; SigLIP 2 scene words; speaker
   similarity ("same voices") — each a new evidence line, no new rung.
4. Hand-off to Cleanup: rung 5 ("Clip of") with proof becomes the
   "clips of a master" lane (safety-critical, codex).

## 6. Tests (five dimensions)

Logic: ladder truth table (every rung, every contradiction). Scale: 100k
records, a 200-member group, budgets. Media matrix: aligned strips on the
synthetic A/B/C/D/E fixtures. Isolation: missing sidecar / missing
fingerprint → "not yet checked", never a wrong word. Sensor: nothing in the
score path opens a media file; the Events page body does no pairwise work.

## 7. Open questions for Rick (one at a time)

1. Should rung 4 ("recorded at the same time") merge two Events
   suggestions automatically, or only pre-answer the question?
