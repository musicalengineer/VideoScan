Brief: N1008-T-CheckMedia | Source: main@e7e482f7 | Wall clock: 40 | Files read: 22
Finding count: 9 (REAL 5 / NEEDS-MAC 4 / NOISE 0)
Verdict: The Check Media rules are mostly sound, but four things need attention. The quick tier's "cut short" Problem probably can never fire on real ffprobe output. The full tier counts decode errors differently from Verify Video, yet writes into the same persisted field. A full card can say "Healthy — every check passed" when the decode did not finish. And none of the thirteen rules' own thresholds is pinned against being loosened.

# N1008-T-CheckMedia — Check Media rules vs tests (merge df616324)

Scope: `MediaOps/CheckMedia/CheckMediaRules.swift`, `CheckMediaRules+Full.swift`,
`CheckMediaInputs.swift`, plus the `VerifyVideoRules` / `VerifyAudio*` pieces they
reuse. Tests: `VideoScanTests/CheckMediaTests.swift`, `CheckMediaMediaMatrixTests.swift`,
`VerifyVideoRulesTests.swift`. Callees followed to settle findings:
`CheckMediaProbe.swift` (windows, tail, args), `CheckMediaJob.swift` (`checkMeasured`,
`persist`), `VerifyVideoProbe.swift` (`decodeArgs`, `decodeWithSignalsArgs`, `runDecode`,
`VideoDecodeTally.noteError`), `MediaReportCard.swift` (`verdict`, `rank`),
`MediaFacts.swift` (`sampleCount`), `ProcessRunner.runProcess` (meaning of the stderr limit).
Readers: every match for `audioVerify*|videoVerify*` in the app target, plus the diffs of
`CopyFamilyAssessor.swift`, `CatalogRowMenuPlan.swift` and `CatalogRowContextMenu+Audio.swift`
(deleted) → `+Media.swift`.

Probe: `probe.py` in the session scratchpad re-implements the quick-tier rules (frame
rate, bitrate bands, distinct-frame gate, A/V length, truncation warning, sample count),
with no ffmpeg. Its output is quoted where it is used.

## Rule → test table

"Delete" = which test goes red if the guard line is removed. "Loosen" = which test goes red
if the value is relaxed (direction stated). "—" = nothing goes red.

| # | Rule / threshold (file:line) | Delete → red | Loosen → red |
|---|---|---|---|
| Q1 | `checkBitrate`: bpp bands per codec family (lossy 3/20, mezz 15/80, lossless 64/256) via `V.checkBitrate`; Problem if severe or bloat (`CheckMediaRules.swift:89-117`; bands `VerifyVideoRules.swift:216-219`) | `capeCodClassIsAProblemOnEveryTimingCheck` (bitrate == .problem); `VerifyVideoCheckTableTests.bitrate` | bands: `VerifyVideoCheckTableTests.bitrate` rows (40 M SD h264 → warning, 400 M → broken, prores 200 M → warning). The Check Media "warning, not problem" branch (bpp 3–20 without bloat) has **no** Check Media test |
| Q2a | `checkFrameRate`: stored > `V.brokenFPS` (1000) → Problem (`:128`) | `capeCodClassIsAProblemOnEveryTimingCheck` (60,000 fps) | only if raised above 60,000 (unit) or 3,000 (matrix `capeCodClassFixture`, Mac only); `thresholdsPinned` pins `brokenFPS == 1000` |
| Q2b | stored outside `cameraFPS` 1...120 → Warning (`:29`, `:135`) | — | — (no fixture between 120 and 1000 fps, none below 1 fps) |
| Q2c | header r/avg ratio > 1.5 → Warning (`:153`, literal) | — | — |
| Q3a | median step < `shortestRealStepSeconds` 1 ms → Problem (`:31`, `:176`) | `capeCodClassIsAProblemOnEveryTimingCheck` (timestamps) | only below ~22 µs (fixture median step = 2/90000 s) |
| Q3b | out-of-order DTS / gap (≥ 1 s and ≥ 20× median) → Warning via `V.checkTimestamps` | `VerifyVideoCheckTableTests.timestampChecks` | same test (1.5 s at a 1 s median → none) |
| Q3c | packet-duration spread p90/p10 > `vfrSpread` 4 → Warning (`:33`, `:190`) | `variableFrameRateIsAWarning` (spread 10) | only above 10 |
| Q4a | A/V diff > 5 s AND > 10 % → Problem (`:219`, literals, not named) | `avLengthTolerances` (100 s of 600 s) | 10 % → above 16.6 %: yes; 5 s → above 100 s: yes; smaller loosenings: — |
| Q4b | diff > `avToleranceSeconds` 1 s, or > 2 % and > 0.25 s → Warning (`:40-42`, `:225`) | `avLengthTolerances` (2.6 s) | 1 s → above 2.6 s: yes. The 2 % / 0.25 s arm: — |
| Q5a | samples ÷ expected within `rateMatch` 1.5 % of a mislabel ratio → Problem (`:45-52`, `:253`) | `mislabelledSampleRateIsAProblem` (falls to the Warning arm) | loosening to ≥ 8.1 % reds `healthyClipIsOKEverywhere` |
| Q5b | drift > 2 % AND > 1 s → Warning (`:44`, `:260`) | — | — |
| Q6a | SAR/DAR odd, size > 16384 via `V.checkDimensions` | `VerifyVideoCheckTableTests.dimensions` | same |
| Q6b | `isSquarePixelSD` (720/704 × 480/486/576 with SAR 1:1 / 0:1 / "") → Warning (`:285`, `:297`) | `squarePixelSDIsAWarning` | n/a (set membership) |
| Q7a | last sampled packet end > file size → Problem (`:309`) | `truncatedFileIsAProblem` | only for slack ≥ ~100 MB. **But see F1: on real files the condition probably never comes true** |
| Q7b | picture shorter than container by > max(2 s, 5 %) → Warning (`:321`, literals) | — | — |
| Q8a | best distinct ratio < `distinctProblemRatio` 0.05 AND stored > 120 → Problem (`:36`, `:348`) | `capeCodClassIsAProblemOnEveryTimingCheck` | the ratio only below 0.0033. Removing the corroboration: `repeatsWithoutAnAbsurdRateAreOnlyAWarning` |
| Q8b | best < `distinctWarningRatio` 0.25 → Warning (`:37`, `:357`) | `repeatsWithoutAnAbsurdRateAreOnlyAWarning` | only above 0.987 (`healthyClipIsOKEverywhere`) |
| Q8c | window counts only if ≥ `minimumFrames` 30 (`CheckMediaInputs.swift:106`) | `tinyWindowsDontCount` | above 10 only |
| F9 | decode: ≥ 100 errors, or ≥ 10 at ≥ 60/min → Problem; 1–99 → Warning; stopped → Problem; partial/skipped → OK/not run (`+Full.swift:21-46`; `VerifyVideoRules.swift:395-418`) | `decodeMapping` (500 → problem); `VerifyVideoRulesTests.decodeOutcomes` (3 → warning, 150 → broken, 52 dense → broken, stopped → broken) | `decodeOutcomes` pins 100 (150 must be broken) and the rate (52 at 60/min) |
| F10/11 | black / freeze share ≥ 0.95 → Problem, ≥ 0.5 → Warning (`+Full.swift:71-77`, literals); filter chain `blackdetect=d=2:pix_th=0.10, freezedetect=n=-60dB:d=5` (`CheckMediaRules.swift:55`) | `blackAndFreezeShares` (both branches) | 0.95 → above 0.999 only; 0.5 → above 0.666. The filter parameters: — (the sensor checks only that the chain string rides along) |
| F12 | sound: damaged → Problem; unhealthy → Warning; no channel carries programme → Warning; peak ≥ −0.1 dBFS → Warning (`+Full.swift:84-127`) | `soundVerdicts` (each branch) | peak: above 0 dB only; silence floor: `BalanceAudioClassifierTests` |
| F13 | interlace: ≥ 50 frames judged; progressive label with share > 0.6, or interlaced label with share < 0.1 → Warning (`+Full.swift:145-157`, literals) | `interlaceLabelMismatch` | 0.6 → above 0.947; 0.1 → below 0.002. The 50-frame minimum: — |
| W | quick tier writes `videoVerify*` when `decodeIsPointless` (`+Full.swift:180`, `CheckMediaJob.swift:200`) | `quickCheckPersistsCardAndTheConclusiveVideoVerdict`, `healthyQuickCheckLeavesVerifyFieldsAlone` | n/a |
| H | headline / card verdict (`+Full.swift:213-229`; `MediaReportCard.swift:156`) | `capeCodHeadlineIsThePlainSentence`, `healthyClipIsOKEverywhere` | — (see F3) |

No test reads a `CheckMediaRules` constant. The comment at `CheckMediaRules.swift:25`
says "named so the tests pin them", but there is no counterpart to
`VerifyVideoRulesTests.thresholdsPinned`. See F8.

## False-positive probes (healthy files)

Probe output, from the re-implemented rules:

```
120 fps phone                          -> ok
120 fps phone, nb/dur 120.4            -> warning        (cameraFPS has no tolerance)
240 fps slo-mo                         -> warning        (VerifyVideo calls 240 plausible)
Android VFR r=90000                    -> warning(header)
1-frame still lasting 5 s              -> warning
4K HEVC 100 Mbit/s 30p / 24p           -> ok (0.4 / 0.5 bpp)
iPhone 4K ProRes HQ 30p ~707M          -> ok (2.84 bpp, mezz band)
DV NTSC 25M                            -> ok (2.41 bpp)
1-frame h264 still 1080p 1.5MB/0.04s   -> warning (5.79 bpp)
480 fps HFR header 720p 40M            -> problem (bloat vs 29.97 fallback)
distinct: 240 fps slo-mo, slow scene   -> problem        (gate opens above 120)
distinct: 120 fps, nb/dur 120.4, still -> problem
A/V: 1-frame still + 10 s music        -> problem
samples: picture 2/3 the sound length  -> problem(48 kHz labelled as 32 kHz)
samples: picture 8.1% short of sound   -> problem(48 kHz labelled as 44.1 kHz)
```

- **DV (interlaced 29.97 / 25):** passes every quick rule. The unit fixture *is* NTSC DV
  (8:9 SAR, `bb`), and the matrix has avi/dv. idet on DV labelled `bb` → OK.
- **4K HEVC at 100 Mbit/s:** fine at 24, 30 and 60 fps (0.2–0.5 bpp against a warning band of 3).
- **VFR iPhone .mov:** passes as long as r and avg are within 1.5×. Packet-duration spread
  stays near 1–2, below the limit of 4. Phones that write r = 90000 get a header Warning
  ("most players cope"). That is by design.
- **Audio-only:** picture rows are "not run" with a reason. Truncation always reads OK
  ("the end could not be sampled"), so audio-only files get no completeness check. Listed
  under Not covered.
- **120 fps, 240 fps, a short picture with long sound:** F4 and F5.
- **1-frame still:** distinct-frames is "not run" (fewer than 30 frames) and timestamps is
  "not run" (one packet). Frame rate gives a Warning if the frame is stamped longer than 1 s.
  With a separate, longer sound track it reaches Problem (F5).

## False-negative probes (broken files)

- **Truncated tail:** F1. The quick tier probably calls it whole.
- **All-black / frozen picture:** quick tier: distinct-frames gives only a Warning without
  the > 120 fps corroboration, which is by design. Full tier: black is caught. Freeze may be
  missed when it runs to the end of the file (F6).
- **Silent sound:** full-tier Warning ("silent"). The quick tier never listens. By design.
- **A/V length mismatch:** caught (Q4).
- **Decode errors mid-file:** caught by the full tier. The count differs from Verify Video's (F2).
- **Decode that ran out of time:** reads OK, with a "Healthy" headline (F3).

## Readers of `audioVerify*` / `videoVerify*` (design doc §4)

What df616324 changed:

- **Writers:** `VerifyAudioJob.write` and `VerifyVideoJob.write` are verbatim extractions
  of the old three assignments (status, note, `Date()`). Check Media calls them only with a
  complete diagnosis (`CheckMediaJob.persist`, `:218-227`), and a failed read writes
  nothing (pinned by `aFailedReadPersistsNothing`). Field meaning, units and the empty-string
  "never checked" state are unchanged.
- **Quick-tier video write:** it happens only when `decodeIsPointless`. That is the same
  diagnosis Verify Video builds: same windows (start, plus the middle when longer than 20 s),
  same `merge`, same `skippedAsPointless`. The two are equivalent, apart from F7 (more
  callers now reach a pre-existing rule).
- **Full-tier video write:** it comes from `VerifyVideoProbe.diagnose(…, signalLine:)`.
  That path changes how stderr is read, so the `errorCount` behind `videoVerifyStatus` can
  differ from Verify Video's. This is F2, the one place where a reader may now see a
  different value for the same file.
- **Full-tier audio write:** `VerifyAudioProbe.diagnose(path:control:)` is called exactly as
  `VerifyAudioJob` calls it (`VerifyAudioJob.swift:285`). Unchanged.
- **Catalog readers.** Unchanged:
  - `CatalogContent+Table.swift:54-60`: tooltip; the diff only adds a focused value.
  - `CatalogQueries.swift:358-361`
  - `CatalogRowMenuPlan.swift:143`: unchanged apart from a comment.
  - `VideoRecord+Presentation.swift:28-33,80`
- **Link Repaired Copy:** the doc lists this reader at `CatalogRowContextMenu+Audio.swift`,
  which df616324 **deleted**. The reader moved verbatim to
  `CatalogRowContextMenu+Media.swift:89` with the same `== "damaged"` test. The doc's list
  is out of date, but the behaviour is the same.
- **Archive readers.** Unchanged:
  - `ArchiveReadiness.swift:134-180`
  - `CopyFamilyAssessor.swift:451,696-697`: only the raw value of `verifyAudioFirst` and
    two caution sentences changed. The enum is not `Codable` and nothing calls
    `init(rawValue:)`, so nothing persisted depends on the old string.
- **Angel readers.** Unchanged:
  - `ArchiveAngelJob.swift:691`: the cache-hit skip. It needs both a non-empty status and
    a Center cache entry, and Check Media fills both.
  - `ArchiveAngel.swift:365`, `ArchiveAngelRowFacts+Record.swift`, `ArchiveAngelCatalogHint.swift`,
    `ArchiveAngelListRowModel.swift:163-169`, `ArchiveAngelReadinessExplanation.swift:322`,
    `ArchiveAngelShowCopies.swift:180`, `ArchiveAngelScorer*.swift`, `ArchiveAngelCandidate+Record.swift:80`.
  - `ArchiveAngelChecks.swift` is missing from the doc's list, but it only mentions the
    fields in a comment (`:13`).
- **`mediaReportCard`:** read only by `MediaInfoSheet` (display). No destructive path reads
  the card's verdict. That is why every card-only finding below is P3.

## Findings

### N1008-T-CheckMedia-F1 — P2 — NEEDS-MAC
**Symbol:** `CheckMediaRules.checkTruncation` (`CheckMediaRules.swift:304-336`), fed by `MediaPacketScan.summarize` (`CheckMediaInputs.swift:85-87`) and `CheckMediaProbe.packetScan` (`CheckMediaProbe.swift:172-186`).

**Scenario:** an MP4 or MOV with its index at the front ("faststart", which is what phones,
HandBrake and Photos write) that loses its last 30 % when a copy is cut off.

1. ffprobe still opens it, and the header durations come from the intact index.
2. The tail window seeks to d−2 s. Those samples lie past the end of the file, so the read
   ends and the window is empty. The middle window may be empty too.
3. When the demuxer meets a packet that runs past the end of the file, it returns only the
   bytes it read, so `pkt.pos + pkt.size ≤ file size`.

So `end > size` (`:309`) never comes true. `streamVsContainerDuration` cannot fire either,
because both lengths come from the same intact index. The row reads **OK — "The file is
whole — its last frame ends inside it."**

`truncatedFileIsAProblem` passes only because its synthetic packet rows run past the file
size, which real ffprobe never produces. The full tier would probably catch it: a "partial
file" error and an early stop in the decode. A quick check alone states the opposite of the
truth, and the card is what Rick sees for files he will never fully decode.

**Smallest test (Mac matrix):** in `CheckMediaMediaMatrixTests`, generate `test_cm_trunc.mp4`
with `-movflags +faststart` and cut it to 70 % with `FileHandle.truncate(atOffset:)`. Then
`#expect(CheckMediaRules.checkTruncation(q).verdict != .ok)`. Expected to fail today.

A cheap detector that does work: compare the byte offset of the last sample in the index
(from `-show_entries packet=pos,size` at the final timestamp, or the index's own end offset)
against the file size. Or treat an empty tail window on a file longer than 2 s as "could
not confirm", not OK.

### N1008-T-CheckMedia-F2 — P2 — NEEDS-MAC
**Symbol:** `VerifyVideoProbe.decodeWithSignalsArgs` / the `stderrLine` closure in `runDecode` (`VerifyVideoProbe.swift:124-133`, `:290-299`) vs `decodeArgs` (`:108-116`) and `VideoDecodeTally.noteError` (`:56-62`).

**The two counting paths:**
- **Verify Video:** runs `-v error`. The ffmpeg CLI compresses repeated identical lines
  (skip-repeated is on by default) into one line plus an untagged
  `    Last message repeated N times`. `noteError` counts **every** stderr line, so a run of N
  identical errors counts as 2.
- **Check Media full:** runs `-loglevel level+info`. In fftools' `opt_loglevel`, a flags
  token with no `+`/`-` prefix resets the flags absolutely, which clears skip-repeated. So
  all N lines are printed and tagged `[error]`, and N are counted.
- **Either way the counts differ.** If this ffmpeg build keeps skip-repeated, the untagged
  "repeated" line falls to `default: break` and the run counts 1.

**Scenario:** a tape transfer with 150 identical `[h264] no frame!`-style complaints in one
run, over 10 minutes.
- Verify Video: 2 errors → `warning`.
- Check Media full: 150 → `broken` (≥ `severeDecodeErrorCount`).

Both are written into the same `videoVerifyStatus` / `videoVerifyNote` through
`VerifyVideoJob.write`. The red row, the `notes:broken` search and the Angel
`.videoRepair` hint then depend on which verb ran last. The design doc's invariant ("a full
check and a Verify job can never disagree") is false here. Arguably Check Media's count is
the more honest one. Either way, the two must agree.

**Smallest test:** a pure test that pushes the same stderr text through both classifiers.
Expose the closure as a static `classify(line:tagged:)`, or test `logLevel` +
`strippingLevelTag` over a fixture:
`["[h264 @ 0x1] [error] no frame!", "    Last message repeated 4 times"]`.
Assert the tagged path counts the same as the untagged path. Also a Mac check that
`decodeWithSignalsArgs` produces "Last message repeated" behaviour identical to `-v error`
(e.g. use `-loglevel +level+info` or `repeat+level+info` and normalize both paths).

### N1008-T-CheckMedia-F3 — P3 — REAL
**Symbol:** `CheckMediaRules.headline` (`+Full.swift:213-229`) and `CheckMediaRules.checkDecode` (`+Full.swift:37-42`).

**Scenario A:** a full check on a USB-2 drive hits the decode budget (`decodeBudgetSeconds`
= 600 s + duration). The coverage becomes `.partial`, giving one `.partiallyChecked`
finding at `.info`.
- The decode row reads **OK**: "Every frame decoded cleanly; partially checked (decoded
  10 min of 2 h 0 min)". The first clause contradicts the second.
- With every other row OK, the headline is "**Healthy — every check passed.**"

**Scenario B:** the decode or sound pass throws because the drive hiccupped. The row is
`.notRun("…")`. The headline still says "Healthy — every check passed.", because only the
all-rows-not-run case is special-cased, and `card.verdict` ranks not-run below OK.

The signal filters make A more likely than under Verify Video: idet, blackdetect and
freezedetect on full-resolution 4K frames slow the decode, which brings the budget closer.
The persisted `videoVerifyStatus` is `ok` in A. That matches what Verify Video writes for a
partial decode, so no reader change. The card wording is new, though, and it overstates.

**Smallest test:** `R.headline(checks: R.quickChecks(F.healthy()) + [R.checkDecode(.failure(.init(reason: "x")))], quick: F.healthy(), tier: .full) != "Healthy — every check passed."`.
Also `!R.checkDecode(.success(diagnosis with .partial)).sentence.hasPrefix("Every frame")`.

### N1008-T-CheckMedia-F4 — P3 — REAL
**Symbol:** `CheckMediaRules.cameraFPS` (`CheckMediaRules.swift:29`), used by `checkFrameRate` (`:135`) and the distinct-frames gate (`:348`).

- `cameraFPS` tops out at 120 with no tolerance, while `VerifyVideoRules.maxPlausibleFPS`
  is 240. `VerifyVideoCheckTableTests.frameRate` row `(240, 240, "none")` and
  `noBloatForRealHighFrameRates` say 240 fps slow motion is real.
- **Result for a genuine 240 fps phone slow-motion clip:**
  - It always gets a frame-rate **Warning** ("outside what cameras record").
  - It opens the "corroborated" gate for distinct frames. A slow or static scene at 240 fps
    can drop below 5 % new pictures under default mpdecimate thresholds (NEEDS-MAC for the
    actual ratio).
  - It then becomes a **Problem**, with the headline "Plays, but its timing is broken:
    ~240 fps — each real frame is stored ~1 times". The factor is 240 ÷ `referenceFPS` 240.
- The same happens to a 120 fps clip whose nb_frames ÷ duration comes out at 120.01+
  (edit lists, rounding): the probe gives warning / problem.
- It is card-only: no verify field is written, because bloat needs > 240 fps and a factor ≥ 4.

**Smallest test:** a quick input with r = avg = 240, nb_frames = 240 × d, and one window
of 300 frames in, 10 kept. Assert `checkDistinctFrames(...).verdict != .problem` and
`checkFrameRate(...).verdict == .ok`. Both fail today. Fix: corroborate on
`V.maxPlausibleFPS` / bloat, not on `cameraFPS`.

### N1008-T-CheckMedia-F5 — P3 — REAL
**Symbol:** `CheckMediaRules.checkAudioSamples` (`CheckMediaRules.swift:244-258`) and `checkAVDuration` (`:219`).

The sample-rate mislabel test compares the sound's sample count with the **picture**
stream's length × the declared rate. The sound's own duration is `duration_ts × time_base`,
so it always agrees with its sample count. That makes the picture length the only reference.

So any file whose picture stream is shorter or longer than its sound by a mislabel ratio
gets the wrong diagnosis:

| Picture ÷ sound | Diagnosis |
|---|---|
| 2/3 | "48 kHz sound labelled as 32 kHz" |
| 0.919 | "48 kHz labelled as 44.1 kHz" |

Each comes as a **Problem**, with the headline "Plays at the wrong speed", plus the fix
"Re-wrap the sound with the right sample rate". Following that advice would make correct
sound play at the wrong pitch.

**Probe example:** picture 40 s, sound 60 s at 48 kHz → ratio 1.5 → mislabel match.

**Related healthy case:** a still picture (one short frame) with a long sound track gets
`avDuration` **Problem**, `truncation` Warning and `audioSamples` Warning. Probe:
0.04 s / 10 s → problem.

The persisted fields are untouched (card only), but the card names a fix that would do
damage.

**Smallest test:** set the healthy fixture's picture `duration` to 400.4 s and keep the
sound at 600.6 s (ratio 1.5). Assert `checkAudioSamples(q).sentence` does not contain
"labelled as". Fix: only claim a mislabel when the container duration agrees with the
picture and `checkAVDuration` is not already a Problem. Otherwise say the lengths differ.

### N1008-T-CheckMedia-F6 — P3 — NEEDS-MAC
**Symbol:** `MediaSignalScan.adding(line:)` (`CheckMediaInputs.swift:144-158`) with `freezedetect=n=-60dB:d=5` (`CheckMediaRules.swift:55`), and `stretchCheck` (`+Full.swift:61-81`).

The parser counts a freeze only from `lavfi.freezedetect.freeze_duration:`.

As far as I know, `vf_freezedetect` logs `freeze_start` when a freeze is detected but
logs `freeze_duration` / `freeze_end` only when motion resumes. It does not flush at end of
stream; blackdetect does flush in uninit.

**Scenario:** a stuck encoder or tape dropout freezes the picture from 0:05 to the end.
There is no duration line, so `freezeSeconds` = 0 and the row reads **OK**, "No frozen
stretches." The ≥ 95 % "frozen the whole way through" Problem is reachable only if the
picture moves again in the last frames.

If instead this ffmpeg build does flush at EOF, the reverse holds: a healthy still-image
clip (title card, photo slideshow export) becomes a **Problem**, "frozen the whole way
through".

`blackAndFreezeShares` uses canned seconds, so neither case is pinned.

**Smallest test (Mac matrix):** a 20 s `test_cm_still.mp4` made with `-loop 1` from one
generated frame. Run `CheckMediaProbe.full` and assert the freeze row reports the stretch
(seconds > 15). Also parse `freeze_start` with no end as "frozen to the end".

### N1008-T-CheckMedia-F7 — P3 — NEEDS-MAC
**Symbol:** `CheckMediaRules.conclusiveVideoDiagnosis` (`+Full.swift:180-188`) → `CheckMediaJob.persist` → `VerifyVideoJob.write`.

A genuine high-frame-rate file whose header says 480 or 960 fps has r and avg both above
240. `referenceFPS` then falls back to 29.97, giving a factor of 16 or more →
`duplicateFrameBloat` → `decodeIsPointless`.

The **quick** tier now persists `videoVerifyStatus = "broken"` ("Don't archive this copy")
on that basis. Probe: 480 fps 720p → problem.

The rule itself is Verify Video's and predates this merge. What is new is that a cheap
quick check, likely to be run over large selections, now writes the persisted broken
verdict. It shows as a red row and the Angel `.videoRepair` hint. Most cameras store
high-speed footage at playback rate, which is why this is NEEDS-MAC: someone needs to
confirm whether any real files in the archive have headers above 240 fps.

**Smallest test:** `conclusiveVideoDiagnosis` with r = avg = 480, nb_frames = 480 × d and a
mostly non-tiny packet sample should be `nil`. Today it returns broken. A safer gate is to
also require `tinyPacketFraction ≥ 0.8` (the "mostly empty packets" signature) before
skipping the decode from the quick tier.

### N1008-T-CheckMedia-F8 — P3 — REAL
**Symbol:** `CheckMediaRules` thresholds (`CheckMediaRules.swift:25-55`, plus literals at `:153`, `:219`, `:321`, `+Full.swift:71/75/145/151/157`, `:118`).

No test reads a single `CheckMediaRules` constant. Guards that nothing pins (delete or
loosen and every test stays green):
- the `cameraFPS` Warning (both ends)
- the r/avg 1.5 header ratio
- the 2 % / 0.25 s A/V arm
- the `sampleCountTolerance` drift Warning
- the picture-shorter-than-container truncation Warning
- the 50-frame idet minimum
- the blackdetect / freezedetect parameters

Loosenings that go uncaught across wide margins:
- `shortestRealStepSeconds` down to 22 µs
- `distinctProblemRatio` anywhere from 0.0033 to 1
- `distinctWarningRatio` up to 0.987
- freeze/black Problem up to 0.999
- the truncation slack up to 100 MB

Several thresholds are unnamed literals despite the "named so the tests pin them" comment.

**Smallest test:** a `CheckMediaRules.thresholdsPinned` test, mirroring
`VerifyVideoRulesTests.thresholdsPinned`, that asserts every constant. Name the literals
first. Add one boundary row each for Q2b, Q2c, Q5b and Q7b, and an edge pair (just inside /
just outside) for Q3a, Q8a and Q8b.

### N1008-T-CheckMedia-F9 — P3 — REAL
**Symbol:** `Gauntlet04BalanceAudioUITests` (`VideoScanUITests/Gauntlet/Gauntlet04BalanceAudioUITests.swift:50-61, :104`).

df616324 removed the catalog "Verify Audio" menu verb. Before the merge it was at
`CatalogRowContextMenu+Audio.swift:65`; nothing under `Catalog/` names it now. The UI test
still waits for `menuItems["Verify Audio"]` ("Context menu never opened") and clicks it
twice. It will fail when run. It does not appear in `scripts/gauntlet/manifest.json` (a
grep for its name finds nothing), so it may be silently stale rather than red.

**Smallest change:** point the test at "Check Media…" → Full, or retire it explicitly.

## Not covered

- `VerifyAudioRules` and `VerifyAudioProbe` internals: Check Media reuses the whole
  diagnosis (`persistedStatus`, `isHealthy`, `balanceAnalysis`). I checked only that the
  call matches `VerifyAudioJob`'s and that `carriesProgram` is pinned
  (`BalanceAudioClassifierTests:71-72`). Their own thresholds were not re-audited.
- **Media matrix gaps for family-archive formats:** MPEG-PS/VOB, MPEG-2 TS / AVCHD
  (field-coded H.264), 3GP, WMV/ASF, FLV. In particular nobody has checked whether ASF or
  millisecond-time-base containers report `duration_time` values that could trip the 1 ms
  `shortestRealStepSeconds` Problem. Worth one ffprobe each on the Mac.
- **Audio-only completeness:** `checkTruncation` reads OK for every audio-only file (no
  packet scan). A truncated WAV or M4A is not checked in the quick tier.
- `MediaVolumeGateHold`, the MFO job lifecycle, cancellation and pause: other rows' scope.
- Matrix tests use `try #require(VerifyVideoTestMedia.toolsAvailable)`. On a machine
  without ffmpeg they fail rather than skip. I did not check how CI treats that.
- I could not run any Swift test, ffprobe or ffmpeg, so every NEEDS-MAC claim about ffmpeg
  behaviour (F1 packet pos/size at EOF, F2 `opt_loglevel` flag reset, F6 freezedetect at
  EOF) is from memory of the FFmpeg source and needs one run on the Mac.

## Blockers & environment

- Linux cloud session: no Xcode, Swift toolchain, ffmpeg or ffprobe. All rules were
  evaluated by reading the code plus a Python re-implementation (`probe.py`, session
  scratchpad, not in the repo).
- No commands failed. On the caller's instruction I did not commit or push (this overrides
  README rule 3's branch push). The report is left in the working tree only.
- What would have helped: an ffprobe binary to settle F1, F2 and F6 directly (each needs
  one run on a generated fixture).
