# The file dossier view — everything we know about one file, in three layers

Status: in flight — 2026-11-05. Rick approved the design; phase 1 (§7 step 1: layers 1 and 2, the three call sites) is
built on `feat/file-dossier-view`, waiting for his spot test. Layer 3 (§5) and the DV clock (§7 step 3) are next.

*Rick said "design it" on 2026-11-05. This is the per-file view in `background_service.md` §6 (view 2), reached the way
Rick asked for it.*

## 1. What Rick asked for

> "When we select Analyze… we just see them in the MFO window, but when we click on them we don't see all the analysis
> like in the script. Should we make it so we can click on the file in the MFO window and see 1. tech data 2. patterns,
> events 3. corpus wide … showing chevrons like > Technical, then > Events and Patterns, then > Corpus wide observations."
> (2026-11-05, after the 10- and 50-file runs of `tools/dossier-demo`.)

## 2. The shape

- **One view, `FileDossierView`, opened from three places.** CLAUDE.md rule 4: one engine per action.
  1. Clicking a file row in the Dossier window (⌘⇧O, `DossierDashboardView`), the MFO window that Analyze… fills.
  2. The inspector's Dossier section. The new view **replaces** the body of `InspectorDossierView`, which already shows
     the inferred date, captions, OCR and the transcript. Those lines move into layer 2, so nothing is lost and there is
     no second dossier view.
  3. A row in the Results sheet (Content Analysis ▸ Results…), next to "Show in Catalog".
- **Three disclosure groups (the chevrons).** Each one is collapsed to a one-line summary, so a file reads in three
  lines. Opening a group shows its lines.
- **Each line says who said it.** A line carries its source (`ffprobe`, `DV clock`, `8B era`, `Whisper medium`,
  `Rick`) and an **ⓘ** pop-over with the evidence: the frames or windows, the cue, the chain of reasoning.
- **Opening the view runs nothing.** It shows stored facts and observations only, which keeps it instant. Analyze…
  and the background helper run the analyzers, as now, and the view fills in as their results land. A missing line
  says why, for example "not transcribed yet" or "no Whisper model on this Mac".

## 3. Mock (the 1990 Christmas tape; the speech line and the derivative line are illustrative)

```
Christmas_1990_2_hours.dv                                          [Show in Catalog]

▾ Technical — DV camcorder tape · NTSC 720×480 interlaced · 2 h 39 m
    Container      raw DV (DIF)                       → a straight tape capture, no re-wrap      ffprobe
    Video          dvvideo 720×480, 8:9 pixels, 4:3, bottom field first                         ffprobe · mediainfo
    Audio          PCM 48 kHz 2 ch                    → DV 16-bit mode                           ffprobe
    DV clock       none in the tape                   → analog tape through a DV bridge          DV clock ⓘ
    File dates     modified 2003-02-11                → when it was copied, never the shoot      file system
▾ Patterns & events — Christmas · indoor · 1990–95 · speech (English)
    Scene          family around a decorated tree, children and a dog                           8B ⓘ
    Event          Christmas                                                                    8B ⓘ
    Era            1990–1995  (your date: 1990 ✓)                                               8B era ⓘ
    Speech         English — "…open that one next…"                                             Whisper medium ⓘ
    People         2 confirmed                                                                  Rick
    On-screen text none                                                                         8B
▾ Across the collection — 1 derivative · 3 parts of the same tape · re-recording
    Derivatives    Christmas_1990_Part3.mov (same footage, Avid re-wrap)                         sound print ⓘ
    Same tape      Part2-28mins.mov, Part3-47mins.mov                                            chain ⓘ
    Re-recording   content 1990 on DV (DV shipped 1995) → older footage copied onto DV           rule ⓘ
    Date window    1988–1992 from Part 3 (Rick 1990)                                             chain ⓘ
    Event          with 4 files: "Christmas 1990" candidate                                     chain ⓘ
```

The colours follow DECISIONS 2026-11-03: grey and blue, never yellow. A machine claim is never shown as a fact. It
carries its source, and `era.none` never shows as an era (DECISIONS 2026-11-01).

## 4. Where each layer's data comes from (all of it already stored, except where noted)

| Layer | Source | Notes |
|---|---|---|
| Technical | the `files` probe columns plus the interpretation rules | The rules move out of `tools/dossier-demo` into Core (`TechnicalReading`), so the script and the app say the same thing. |
| Technical, DV clock | not stored yet | `background_service.md` §7 step 2, the DV datecode analyzer. Until it lands the line reads "not read yet". |
| Patterns | `provenance_assertions` (era), `captions`, `transcripts`, `people_tags`, `inferred_dates` | The same tables the demo read; read-only. |
| Across the collection | a precomputed **setup index** plus per-file joins | The four rules the 50-file run showed were weak are fixed first (§5). |

## 5. Before the corpus layer: the four fixes from the 50-file run

1. **A capture setup must identify a device.** A generic DV signature (720×480, 48 kHz, 2 ch) is not a camera. A DV
   setup needs the DV clock or the camera's make and model; without them it is a "format group" and bounds no dates.
2. **A camera's span replaces ±2 years.** A camera is used for years, so the window is the span of its dated members,
   widened only by what the evidence allows. A single dated sibling gives a weak hint, never a window.
3. **Our own encodes are transfers.** `Lavf` / HandBrake / `.vs.archive` / `.vs.preserve` outputs describe our tools,
   not the shoot.
4. **Derivatives come first.** Files that are the same footage (matching sound prints, a re-wrap, `vs-edit` /
   `_balanced` / `_repaired`) form one **family** with one original. The family is listed under "Derivatives" and
   never counted as an event or as separate evidence.

Event candidates stop using "same folder" alone; a folder records how Rick filed something, not what happened.

## 6. Tests (rule 8)

- **Logic:** each rule in §5, each layer-1 reading, and the summary lines.
- **Truth:** every line equals its stored row (signer, value, evidence), and a missing analyzer says so in words.
- **Scale:** 100k files. The view opens in under 100 ms (measured; the budget is set from the first measurement), and
  the setup index builds off-main within a stated budget.
- **Isolation:** a file with no probe, an unreadable transcript, an unknown signer.
- **Media matrix:** the technical readings over mp4/h264, mov/prores, mkv/ffv1, mxf, avi/dv (the existing fixtures).
- **A sensor** that the three call sites open the same view (one door).

## 7. Order of work

1. **Layers 1 and 2** (the data exists): `FileDossier` in Core plus `FileDossierView`, wired to the three call sites.
   It replaces `InspectorDossierView`'s body.
2. **The §5 fixes plus layer 3:** the setup index, families, windows and event candidates, each line with its chain.
3. **The DV clock analyzer** (`background_service.md` §7 step 2) fills the DV clock line.

## 8. Rick's calls (2026-11-05)

1. **All three groups start collapsed.**
2. **Clicking a file in the Dossier window does what the other MFO verbs' windows already do** with a clicked file. If
   that proves awkward, we move it to the inspector.
3. **Corpus lines: show what we have** (the sibling files by name), then Rick looks and decides.
