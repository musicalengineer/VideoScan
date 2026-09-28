# Archive Angel — the wise recommender (design + staged plan)

*Written 2026-09-25 (Fable 5.1 session) as the answer to
`archive_angel_recommendation_problem.md`. Status: DESIGN with Stage 1–3
implemented on lanes the same day. Rick decides the open questions at the end.*

## 0. What the live catalog said (measured 2026-09-25, 00:15 evidence)

| Fact | Number |
|---|---|
| Records / live video records | 13,889 / 9,055 |
| Unarchived video ≥ 2 min (the Angel's real pool) | 1,039 files, 276 h |
| … of which audio never verified | **1,036** (3 "ok") |
| … video never verified | 1,039 |
| Recommended (Ready 60 · Needs a date 20 · Worth a look 33) | 113 |
| … audio never verified | **111 of 113** |
| … under 5 min / over 30 min | 52 / 30 (median 6.2 min) |
| … dated "2026" by a conversion stamp or capture-tool filename | **22** (VHS tapes digitized in 2026, ProRes/FFV1 exports stamped 2026) |
| … undated | 17 |
| … the Angel's OWN buffer companions (`VideoScan Buffer/ArchiveAngel/batch-…`) listed as Worth a look | 2 |
| … Person Finder machine compilations (`PersonSearchResults/Donna_compilation_*`) listed as Ready | 3 |
| Records with a footage group (Find Similar Footage applied) | **12** of 9,055 |
| Files > 1 Gbps average bitrate (broken encodes: 43 GB for 37 s) | 116 |
| Years with the deepest unarchived backlog (unarchived ≥ 2 min / archived) | 2010: 156/27 · 2011: 77/7 · 2023: 70/2 · 2007: 62/15 · 2009: 51/14 · 2000: 43/3 |

So the "10 of 10 Needs audio checked" screen was not a fluke: it is the whole
pool. And three of the list's problems are not scoring problems at all — they
are trust problems: a wrong date shown as Ready, the Angel's own working copies
shown as material, machine outputs shown as originals.

## 1. Answers to the six hard questions

**1. When does the machine do the work?** Whenever the work is a *read* and
the result is a *fact on the record*. Verify Audio reads the file and writes
`audioVerifyStatus`; nothing is moved or changed. So the Angel runs it
**before** a file is shown as needing it — on the top of its own list, one file
at a time, behind the same per-volume gate every other reader uses, parked while
the person is working, budgeted, logged per file, never on FamilyArchive. The
same door later admits a bitrate sanity check and Verify Video. Balance Audio
is a *write* (a new derivative file); it stays inside Prepare, where the person
has pressed a button, and the original is never touched.

**2. Unit of recommendation.** The *material* (footage), presented through its
most-original member. The machinery exists (`footageGroup` collapse,
`footageOriginal` preference) but had data for 12 records. The Angel now keeps
Find Similar Footage current itself (it is a metadata-only pass, ≈ 1 s, writes
only changed answers), and a material whose original is already archived is
never recommended again through another member. The row says "N files hold the
same footage — this is the original".

**3. Derivatives.** One card: the original as-is, plus `_balanced` (and later
other restored versions) as versions of it, produced during Prepare only when
`BalanceAudioFix.refusalReason` says the track is fixable. Mono-vs-unbalanced is
decided by the existing verify rules; a verify note that is *informational*
("mono", "surround") is verified, not a need. Nothing in this design edits an
original.

**4. Clip-of detection.** Not in this stage. The cheapest reliable signal is
the labelled audio-fingerprint spike already planned (`find_original_design.md`
v2, Phase 2). Until then: name/duration windows (Find Similar Footage) and the
2-minute floor.

**5. The list's shape.** Ten rows. Every row is one of exactly three things:
*Ready* (nothing missing — one click), *Needs you* (a date to confirm, a look, a
repair decision — one quick human touch), or *Being checked* (the machine is on
it). Never-checked is not a state a row may be shown in while the checker has
budget. "Angel is not working hard enough" is now a number: the count of
recommended rows that are neither Ready nor Needs-you nor Being-checked (the
*stalled* count). Target 0. The strip prints it and the log prints it after
every sweep and every check.

**6. Trust.** Every automatic step is a read, is logged with the filename and
the verdict, and is visible in the Media File Operations window as an ordinary
job. Settings (default ON, one toggle each): "Check recommended files in the
background", "Keep footage groups current".

## 2. The pipeline order (what runs before a file is shown)

```
catalog change ──► Assess (sweep, metadata only, ≈ 2 s)
                      │  classes: Ready · Needs a date · Worth a look · …
                      ▼
                   Keep footage current (Find Similar Footage, metadata, ≈ 1 s,
                      once per launch + when stale) ──► re-assess
                      ▼
                   Check (Verify Audio on the top of the list, bytes,
                      1 at a time, gated, parked, budgeted) ──► record verdict ──► re-assess
                      ▼
                   Show: Ready / Needs you / Being checked
                      ▼
                   Prepare (person presses) ──► Review ──► Promote (unchanged)
```

## 3. Signal fixes (rules v12) — truthful readiness

1. **Working copies are never material.** A file under the Angel's buffer root
   is a safety-class floor (`angelWorkingCopy`). Live: 2 rows.
2. **A conversion stamp is not a capture date.** `RecordDateResolver`: when the
   embedded date was stamped by a transcoder or has no camera origin
   (confidence ≤ 0.85) and the *filename* carries a year that disagrees by
   more than 2 years, the filename year wins (year precision, low confidence)
   — the same shape as the GH #166 rule for content evidence. Live:
   `DickyDonnaDancing1992.mov` (stamped 2026-04-03) → 1992;
   `Christmas1990-part1` (stamped 2023) → 1990.
3. **A file dated this year that looks like a digitization needs its date
   confirmed.** New rule field `yearsAgo`; default class rule
   `recentDigitization`: dated within the last year, no device model, codec in
   {ffv1, prores, dvvideo, mpeg2video, mjpeg} → **Needs a date**, reason
   "Dated 2026, but it looks like a digitization of older footage — confirm
   when it was filmed". Live: the Converted_VHS_Tapes_2026 set (Cape, Montana,
   Matt's 1st birthday) stop being "Ready" under 2026.
4. **Broken encodes need a look, not a promote.** Default class rule
   `absurdBitrate`: averageKbps ≥ 1,000,000 → Worth a look, plus a printed line
   "Unusually large for its length — check it before archiving".
5. **Machine compilations are not originals.** `personsearchresults` joins the
   app-cache folders; `*_compilation_*` joins the stem globs. Live: 3 rows.
6. **A material whose original is archived is done.** Projection flag
   `archivedFootageOriginal` (the footage group's likely original, or an
   Identical twin, is archived; Possible groups never count) → the existing
   "A copy is already in the archive" rejection with the footage note.

All of it is policy data (`AngelPolicyDefaults`, bundled JSON regenerated,
pinned) except the resolver rule and the two projection flags.

## 4. Angel Checks (Stage 2)

`ArchiveAngelChecks` — a main-actor loop beside the sweep, owned by the façade.

- **What:** for the first `lookahead` (20) ranked recommendations whose audio is
  `.notVerified`, whose volume is mounted and not FamilyArchive, and whose file
  exists (off-main stat): start the ordinary `VerifyAudioJob` through a new seam
  `AngelJobRunner.startVerifyAudioForAngel` (no user origin — the MFO window
  does not come forward). One at a time. The per-volume gate does the rest.
- **When:** after a complete sweep; then whenever the last check finishes;
  parked while the sweep's interaction gate says the person is working (quiet
  window 120 s, not the sweep's 3 s — this reads bytes), while a scan / Angel /
  Promote job runs, and off entirely when the setting is off or the viewer is
  read-only.
- **Budget:** `maxPerHour` (12) and `maxPerLaunch` (200); a file is checked at
  most once per launch (a failed verify persists nothing — that is the existing
  rule — so it is not retried until relaunch).
- **Result:** the verdict lands on the record (the verify job's own persist);
  the façade's recount runs; the row becomes Ready, Needs audio repair, or keeps
  its informational note. The log prints one line per file:
  `Archive Angel check: <file> — ok | damaged (<note>) | failed (<why>)` and a
  summary after each batch of ten.
- **Row words:** a queued/running check shows "Checking the sound…" instead of
  "Needs audio checked"; the Promote button stays as it was.
- **Headline:** `N ready · M need you · K being checked` (+ prepared when > 0).
  The stalled count goes to the log, and to the strip only when > 0
  ("3 waiting for a check").
- **Not done here:** waking a sleeping drive is not detected; mounted = usable.
  Rick decides (question 3 below).

## 5. Keep footage current (Stage 3)

After the first complete sweep of a launch, and again when the newest
`footage.scannedAt` is older than 24 h and the catalog has changed, the façade
starts `Find Similar Footage — whole catalog` through a seam. It is queued
behind any run in progress (the verb's own rule), never refused, and its apply
writes only changed answers. Setting "Keep footage groups current", default ON.

## 6. Metric and reward

- **Files decided per session** = ledger `archived` + `angelSkipped` (+ a rest)
  per calendar day — the goal's own number; the strip's help text quotes today.
- **Stalled** = recommended rows that are none of Ready / Needs-you / Being
  checked. Logged after every sweep and check; target 0.
- The wings and the bell (25 promotes in 24 h) stay Phase 4 of the curation
  plan.

## 7. Stages and status

| Stage | Content | Status |
|---|---|---|
| 1 | Signal fixes §3 (rules v12) | lane `feature/angel-truthful-readiness` |
| 2 | Angel Checks §4 | lane `feature/angel-checks` |
| 3 | Keep footage current §5 | in lane `feature/angel-checks` (façade wiring) |
| 4 | Timeline-gap signal (stratified coverage: years with a deep unarchived backlog and few archived files earn points) | next |
| 5 | Folder decisions from a row ("never propose from this folder" → a policy.json floor the app writes for you) | design |
| 6 | Version cards: an archived original whose `_balanced`/restored version is not archived gets a "add as a version" recommendation | design |
| 7 | Clip-of detection (labelled audio-fingerprint spike) | `find_original_design.md` v2 Phase 2 |

## 8. Decisions for Rick

1. Background Verify Audio on recommended files, default ON, 12 files/hour,
   only while you are not using the app — yes? *(recommend yes)*
   **DECIDED 2026-09-25 (Rick): yes — default ON, 12/hour.**
2. Keep footage groups current automatically (a 1-second metadata pass that
   writes footage groups into the catalog) — yes? *(recommend yes)*
3. May a background check touch a mounted drive that may have spun down? Today
   the answer is yes (mounted = usable). A per-drive opt-out can be added.
   *(recommend: leave it; the per-volume gate already serialises reads)*
4. A file dated this year with no camera origin in a preservation codec is
   "Needs a date" until you confirm — even a genuine 2026 recording. One click
   each. Acceptable? *(recommend yes: a year you typed outranks everything)*
5. The filename-year-beats-conversion-stamp rule changes the catalog's date for
   every such file, not only the Angel's view (Promote files them under the
   filename year, marked low confidence). *(recommend yes — one truth)*
6. A footage group whose likely original is an *export* (the camera
   original is not in the catalog) is still treated as done when that
   export is archived: its other members are excluded as "The original of
   this footage is already in the archive". Narrow it to groups whose
   original has camera evidence? *(QA v12 #7; recommend: keep — drain the
   catalog; the Readiness sheet names Find Similar Footage as the reason)*
