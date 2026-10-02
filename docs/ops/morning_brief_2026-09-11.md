# Morning brief — night of 2026-09-10 → 11 · Theme T10 (Archive Angel top-50 hygiene)

**Owner:** Claude · **Reviewer:** codex (record: [review details](codex-t10-review-2026-09-11.md)) · **Cap:** 20:16–00:16 ET, closed ~22:00 · **implementation/corpus head:** 12fdc2fb (pushed; subsequent commits document the handoff)

## 🔴 CI / nightly status (baseline, NOT tonight's regressions)
- **main CI was already red before T10:** run [34540926129](https://github.com/musicalengineer/VideoScan/actions/runs/34540926129) on 8308fa89 — unit step fails (possessorCandidates 2.047 s > 2 s budget; transcript render appendRows 28 > 2; cleanup-matrix ffmpeg cases; vorbis integration). Python tests + Pages green. `CICanary mustFail` is intentional.
- Last full local nightly (9/10): 7,018 pass / 1 fail (badgeFillsArePairwiseDistinct, fixed 3700ebff) / 56 skip. No new full nightly tonight — focused suites only (below).

## Metric: false-positive classes in the top 50 candidates — 3 known → 1 shipped, 2 parked
| Class | Live evidence (rulesVersion 3, 11,727 considered) | Tonight |
|---|---|---|
| Downloads / rips on length alone | 15 commercial films + 6 downloads in the top 50, scoring 103–113 | **SHIPPED — H1** (main bb172f6c): unmarked + delivery codec + < 4 Mbit/s + ≥ 20 min → capped at grade C, never rejected; preservation codecs and family-origin folders exempt |
| Both halves of a duplicate group | 4 pairs in the top 50 | **PARKED — H2** → GH #178 (branch `fix/angel-hygiene-1` e622f68a, unmerged) |
| Derivative exports beside originals | 6 in the top 50; 300 in the catalog | **PARKED — H3** → GH #179 (1cce19cb, unmerged) |

**Projected effect of H1** (Python replay of the rule over the same evidence; the real numbers arrive at the next in-app assessment, which re-derives at rulesVersion 4): grade A 55 → 19, B 182 → 143 over the **eligible cohort of 968**; 46–50 rows capped across the owner's interim projections; 21 films/downloads leave the top 50. The 21 replacements are mostly family-media entries, but include **Silence.m4v with unknown codec**, an unresolved false positive. These are interim projection figures, not a verified production re-profile of final H1d. (The sidecar's X count is 10,773; the "X 14" in the before-table below is the zero-score subset of the eligible cohort, not the full-catalog rejection count.)

**Second finding, bigger than the theme:** `userNotes` holds machine text on 9,977 of 13,842 records — ffprobe stderr, "Last message repeated", the FindPerson recipe output, Promote "copy at" lines; ~10 records hold a note a person typed. "Has notes" was therefore +5 on most of the catalog and, in H1's cap, would have counted as a human mark (the pre-existing hard floors key on stars only and were not affected). H1 ships a writer-signature classifier (exact census prefixes + the ffmpeg `[x @ 0x…]` header; "[1984] Dad and Donna…" stays human). → **GH #176 (High Priority)** for the writers + a migration.

**Honest trade-off:** Part2.mp4 (MoviesExpansion, h264 2.4 Mbit/s, 68 → capped 59, still eligible) is the one known family casualty; two derivatives of Thanksgiving-Raw_Default drop to C (their svq3 original keeps 121). An unmarked low-rate h264 transcode of an old tape with no family folder marker would be capped too — codec+rate cannot tell it from a rip; a star, or a folder marker (`.imovielibrary`, `.imovieproject`, iMovie Events, Family Movies, Home Movies, Original Media), exempts it.

## SHAs and evidence
| What | Where | Gate |
|---|---|---|
| H1 cap + note classifier + family-origin markers (H1, H1b, H1c, H1d) | main **bb172f6c** (H1-only branch `fix/angel-hygiene-h1`, cherry-picked) | 66 tests / 13 Angel suites — `/private/tmp/VideoScan-t10-gate-h1-bb172f6c.log` |
| H2, H3 (parked) | `fix/angel-hygiene-1` e622f68a, 1cce19cb (kept, unmerged) | codex blockers recorded in #178/#179 |
| GH #175 Archived column sorts (Rick's High Priority ask; separate from T10) | main **3b94c35e** (`fix/gh-175-archived-sort`, cleared by codex) | 16 tests / 3 suites — `/private/tmp/VideoScan-175-tests2.log` |
| T2 harvest: 3 live turns lv260910-007..009 with expectations | main **12fdc2fb** (corpus) | Python corpus tests 46 pass |
| T2 strict replay | binary bb172f6c (Debug, built 21:09); corpus at 12fdc2fb; host 127.0.0.1 | **18/20 clean** — `/private/tmp/hallie-strict-main-bb172f6c-localhost` |

## T2 findings (bounded; no Hallie code touched tonight)
- Codex independently checked the result files: 20 completed, 18 clean, two flagged, no missing turns or timeout. The strict corpus SHA-256 is `2cd2b60f7de01c4923fad9162a18dbd5bdb1377a23875b7ab629158da104b2c3`. The **three newly harvested advisory questions were not exercised by this strict-only run**. Tree-backed answers in the result establish that this run had family data; they do not establish full fleet data parity.
- Runs 1–2 of the strict set scored 16/20 with the SAME three "language helper unreachable" turns: **connectivity, not routing.** ollama on the M4 binds 127.0.0.1 only; `RicksM4.local` resolves to IPv6 link-local only; the headless shell's default host list `[RicksM4.local, ricksm5.local]` cannot reach the model from the M4 itself (the app is configured with 127.0.0.1, so it works). → **GH #181 (High Priority)**, incl. the fleet implication (M5/M1 cannot use the M4 as model host while it binds loopback) and a sensor (a run whose every translator turn fails must fail as "translator unreachable", not grade 80 %).
- Run 3 with `--host 127.0.0.1`: 18/20. Remaining: `strict-011` "tell me about dad" → **Dafydd ab Einion (b. ~1360, Wales)** — a bare kin word bypasses the `my/our` relative regex and fuzzy-matches a tree name → **GH #180 (High Priority)**, codex's routing area; `strict-004` "whom did he marry" → known "passed away" wording flag.

## Issues filed tonight
#176 userNotes pollution (HP) · #177 cancelled Angel batches stuck "preparing" · #178 H2 parked · #179 H3 parked · #180 "dad" → Dafydd (HP) · #181 harness/model host (HP)

## Reviewer record
codex replied to every checkpoint inside its cadence; no silent windows either way. Two H1 blockers accepted and fixed (bracketed human notes; a suite selector — `ArchiveAngelPromoterRuleTests` had never run under the name used all day). H2/H3 blocked on rule defects + scope and parked per protocol; the owner-declared scope expansion was withdrawn with them. #175 blocked once (per-render date parsing), fixed via the per-version snapshot, cleared.

## Decisions for Rick (max 3)
1. **Scope for H2/H3:** the evidence pick path (`selectFromEvidence`) and the two candidate producers sit outside the scorer. Allow the Angel to touch them (then #178/#179 are a morning's work), or keep the scorer-only rule and accept duplicates/derivatives in batches for now?
2. **The M4 as a fleet model host:** is serving other Macs required? Local replay already works through `127.0.0.1`; fixing that local harness default need not expose the server to the network. If fleet access is wanted, choose the host and access controls deliberately; binding all interfaces is a separate network-exposure decision, not a prerequisite for local tests. (#181)
3. **Photo question still open:** "Pa O'Connor British Army" — Christopher or Daniel? (changes what Hallie says about the photo)

Morning list (authorized, no decision needed): gallery 4a82887f blocker fix before merge (codex #1298: personFolders ordering; malformed-ID fallback); #177 cancelled-batch settle; #175 advisory test (mutate archivedAt → revision bump → order refresh).

## What was not done and why
- H2/H3 were not merged: concrete rule defects and unapproved file-scope expansion; retained branches and issues contain the work.
- No final in-app Archive Angel assessment was run: production sidecar remained read-only. Appendix B is the interim top-50 entry/exit delta, not a complete final-H1d ranked table.
- No new full nightly or complete Hallie corpus run finished within this theme. At reviewer close, [CI on the brief commit](https://github.com/musicalengineer/VideoScan/actions/runs/34552566841) was still running; Python Tests and Pages had passed.
- Gallery fixes, the remaining Hallie defects, and additional sort invalidation/UI tests were left for follow-up to keep the work bounded.

## Appendix A — top 50 BEFORE (live sidecar, rulesVersion 3, 2026-09-11 00:10 UTC)
```
BEFORE — rulesVersion 3 computedAt 2026-09-11T00:10:12Z considered 11727
grades: {'A': 55, 'B': 182, 'C': 584, 'D': 133, 'X': 14}
 # score     dur     GB    kbps filename | folder tail | first why
 1   137    9553  34.36   28771 Christmas_1990_partial.dv | /iMovie Events.localized/Christmas1990 | Looks like Donna (machine)
 2   126    3651  13.84   30314 DVD1992_5Chapters.mov | grater/QuicktimeMovies_AndOtherFormats | Looks like Donna (machine)
 3   126    3651  13.83   30311 FranklinAndCapeCod_July1991.mov | grater/QuicktimeMovies_AndOtherFormats | Looks like Donna (machine)
 4   126    7338  46.82   51051 Cape-1993-archive.vs.edit.mov | /Volumes/CrucialX10/editable_versions | Looks like Donna (machine)
 5   121    5629   0.32     455 Thanksgiving-Raw_Default.mov | grater/QuicktimeMovies_AndOtherFormats | Looks like Donna (machine)
 6   121    1715   5.84   27243 Christmas-1990-something.mov | /Users/rickb/Movies | Tim (confirmed)
 7   119    4019  42.76   85127 Franklin_Dan_Kindergarten_NV12_2.mkv | sion/Converted_VHS_Tapes_2026/Misc1990 | Looks like Donna (machine)
 8   113    3933   0.56    1130 HIS_Disc One_DL.mp4 | etworkBackups/Donna's Backups/Spinning | Looks like Donna (machine)
 9   113    5349   0.62     933 HSRW_Pt1_DD.mp4 | Backups/Spinning/HandspinningRareWools | Looks like Donna (machine)
10   113    5419   0.77    1136 SpinArt_Download.mp4 | etworkBackups/Donna's Backups/Spinning | Looks like Donna (machine)
11   113    3604  29.89   66362 CapeCodJune1998-Peekaboo.vs.preserve_balan | /Volumes/CrucialX10/editable_versions | Looks like Donna (machine)
12   113    8218   2.25    2194 Kill Bill Vol 2.mp4 | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
13   113    5997   0.70     933 HSRW_Pt2_DD.mp4 | Backups/Spinning/HandspinningRareWools | Looks like Donna (machine)
14   113    3723   3.74    8032 Christmas2010_In_Westford.mov | space/CheesegraterArchive/ExternalRAID | Looks like Donna (machine)
15   113    3651  13.84   30314 WholeSequence1991.mov | grater/QuicktimeMovies_AndOtherFormats | Looks like Donna (machine)
16   113    3723   3.74    8032 Christmas2010_In_Westford.mov | iskWorkspace/Cheesegrater_ExternalRaid | Looks like Donna (machine)
17   113    5497   0.78    1129 HIS_Disc Two_DL.mp4 | etworkBackups/Donna's Backups/Spinning | Looks like Donna (machine)
18   113   10259   2.64    2061 Gladiator.mp4 | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
19   113    6644   1.88    2262 Kill Bill Vol 1.mp4 | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
20   108    9553  34.36   28771 clip-135-02-05 05;27;15 1.dv | /iMovie Events.localized/Christmas1990 | Looks like Donna (machine)
21   108    3860  22.78   47221 CapeCod_1995_Rocas_etc.mov | /Volumes/CrucialX9/editable | Looks like Donna (machine)
22   107    3828  10.95   22892 Christmas2010Westford_compilation.mov | /Volumes/CrucialX10/editable_versions | Looks like Donna (machine)
23   106    7338  60.67   66144 Cape-1993-archive.mkv | ion/Converted_VHS_Tapes_2026/Cape-1993 | Looks like Donna (machine)
24   106    3604  37.09   82331 CapeCod_etc_1997.mkv | /from_Mini2TB/Videos from Cheesegrater | Looks like Donna (machine)
25   106    7969   2.29    2300 CROSSROADS_1.m4v | umes/SanDiskWorkspace/FromCheesegrater | Looks like Donna (machine)
26   105    2511   9.03   28772 t3-v.mov | ry.imovielibrary/9-4-19/Original Media | Has captions, camera date
27   105    3764   0.41     878 DraftingLongShort.mp4 | etworkBackups/Donna's Backups/Spinning | Has notes, camera date
28   105    3358  20.38   48564 Franklin_1988.vs.edit.mov | /Volumes/CrucialX10/editable_versions | Looks like Donna (machine)
29   104    2601   9.85   30311 Long Sequence - New Hampshire Christmas .m | grater/QuicktimeMovies_AndOtherFormats | Looks like Donna (machine)
30   104    7338  60.67   66144 Cape-1993-archive.mkv | ion/Converted_VHS_Tapes_2026/Cape-1993 | Looks like Donna (machine)
31   103    2829  10.72   30314 Part3.mov | rchive/osx10.8_backup/rickb/Desktop/EP | Looks like Donna (machine)
32   103    6747   0.73     871 Crash.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
33   103    7428   0.73     791 The Notebook.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
34   103    7400  50.33   54416 cape-1992-edit.mov | /Volumes/CrucialX9/editable | Looks like Donna (machine)
35   103    3733   2.94    6297 Kids2004.mpg | grater/QuicktimeMovies_AndOtherFormats | Looks like Donna (machine)
36   103    5422   1.08    1593 Thanksgiving2009Sequence.mov | grater/QuicktimeMovies_AndOtherFormats | Played 3 times, last on 2026-06-14
37   103    6998  41.59   47540 Christmas_1994_etc.vs.edit.mov | /Volumes/CrucialX9/editable | Looks like Donna (machine)
38   103    6103   0.73     963 The Usual Suspects.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
39   103    8881   0.73     662 Pulp Fiction.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
40   103    7384  50.28   54479 cape-1992-edit_trimmed.mov | /Volumes/CrucialX9/editable | Looks like Donna (machine)
41   103    4854  17.46   28772 New TapeV01.6_4DD754DD88921.mxf | ook/media_backup/Avid MediaFiles/MXF/1 | Looks like Donna (machine)
42   103    7969   2.29    2300 CROSSROADS_1.m4v | space/CheesegraterArchive/InternalRaid | Looks like Donna (machine)
43   103   11763   5.08    3453 Troy.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
44   103    5184   0.73    1132 Meet the Spartans.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
45   103    7829   0.73     751 The Prestige.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
46   103    5032  31.37   49867 2026-07-05_13-15-36.vs.edit.mov | /Volumes/CrucialX9/editable | Looks like Donna (machine)
47   103    6122   0.74     965 American Psycho.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
48   103    6779   0.74     867 Forgetting Sarah Marshall.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
49   103    5629   5.08    7217 Thanksgiving-Raw_Default_denoise_thm2_nyx3 | /Volumes/CrucialX9/Video Workspace | Looks like Donna (machine)
50   103    7792   2.03    2089 The Manchurian Candidate.avi | space/From_Breen_NetworkBackups/Movies | Looks like Donna (machine)
```

## Appendix B — top 50 AFTER H1 (projected by replaying the rule; grade cohorts as labelled above)
```
PROJECTED AFTER H1 (python replica; real numbers come from the next in-app assessment)
grades before: {'C': 584, 'B': 182, 'D': 133, 'A': 55, 'X': 14} → after: {'A': 19, 'B': 143, 'C': 624, 'D': 168, 'X': 14} | rows capped: 46 | records losing the machine 'notes' point: 633
LEFT the top 50 (21):
  - HIS_Disc One_DL.mp4 | h264 | ckups/Donna's Backups/Spinning
  - HSRW_Pt1_DD.mp4 | h264 | Spinning/HandspinningRareWools
  - SpinArt_Download.mp4 | h264 | ckups/Donna's Backups/Spinning
  - Kill Bill Vol 2.mp4 | h264 | om_Breen_NetworkBackups/Movies
  - HSRW_Pt2_DD.mp4 | h264 | Spinning/HandspinningRareWools
  - HIS_Disc Two_DL.mp4 | h264 | ckups/Donna's Backups/Spinning
  - Gladiator.mp4 | h264 | om_Breen_NetworkBackups/Movies
  - Kill Bill Vol 1.mp4 | h264 | om_Breen_NetworkBackups/Movies
  - CROSSROADS_1.m4v | h264 | DiskWorkspace/FromCheesegrater
  - DraftingLongShort.mp4 | h264 | ckups/Donna's Backups/Spinning
  - Crash.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - The Notebook.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - The Usual Suspects.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - Pulp Fiction.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - CROSSROADS_1.m4v | h264 | eesegraterArchive/InternalRaid
  - Troy.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - Meet the Spartans.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - The Prestige.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - American Psycho.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - Forgetting Sarah Marshall.avi | mpeg4 | om_Breen_NetworkBackups/Movies
  - The Manchurian Candidate.avi | mpeg4 | om_Breen_NetworkBackups/Movies
ENTERED the top 50 (21):
  + Silence.m4v |  | Media.localized/Movies/Silence
  + t3-v.mov | dvvideo | elibrary/9-4-19/Original Media
  + Christmas2008.mov | dvvideo | s/SanDiskWorkspace/More_Videos
  + NV12.mkv | ffv1 | /Converted_VHS_Tapes_2026/1991
  + Christmas2008.mov | dvvideo | lumes/Projects/MoviesExpansion
  + WholeSequence1991.mov | dvvideo | uicktimeMovies_AndOtherFormats
  + DVD1992_5Chapters.mov | dvvideo | uicktimeMovies_AndOtherFormats
  + DadThanksgiving1984-Part1-Avid_cleaned.mov | prores | uicktimeMovies_AndOtherFormats
  + Clip 06.dv | dvvideo | apeCod1997.iMovieProject/Media
  + Untitled-video-only.mov | dvvideo | jects/Christmas2006-video-only
  + FranklinAndCapeCod_July1991 | dvvideo | uicktimeMovies_AndOtherFormats
  + Part1.mov | dvvideo | sx10.8_backup/rickb/Desktop/EP
  + xmas-1990-part1.mov | dvvideo | sx10.8_backup/rickb/Desktop/EP
  + DansBaseballAndMore.mkv | ffv1 | 026/Dan_baseball_1991_and more
  + P216.mkv | ffv1 | verted_VHS_Tapes_2026/Misc1990
  + Christmas-c1990s.flv | vp6f | id/Family Movies/Christmas1990
  + Untitled1-video-only.mov | dvvideo | jects/Christmas2006-video-only
  + NV12.mkv | ffv1 | /Converted_VHS_Tapes_2026/1991
  + New TapeV01.6_4DD754DD88921.mxf | dvvideo | a_backup/Avid MediaFiles/MXF/1
  + clip-135-02-05 05;27;15 1.dv | dvvideo | id/Family Movies/Christmas1990
  + Christmas1997-clip1.mov | dvvideo | uicktimeMovies_AndOtherFormats
```
