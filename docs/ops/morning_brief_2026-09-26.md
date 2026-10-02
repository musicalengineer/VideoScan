# Morning brief — 2026-09-26

Plan (written 2026-09-25 evening): stability & quality night — CI to green, full battery on the M5, qwen reviews verified in-house, Hallie replay. No features.

## CI / nightly — read first
- ✅ **CI is GREEN on main**: run 36228511960 on f95138f5. It's the first complete, honest pass in days; the full plan ran and only the canary failed.
- **The recurring "hang" was a memory blowup, not a deadlock.** The test host reached a **43 GB footprint** on the 7 GB runner and was killed. Two causes:
  - `VideoScanModel` registered 8 NotificationCenter block observers and never removed them. The tests build it 716 times.
  - `VolumeReachability` posted one notification per changed key: about 99k posts from one scale test, each fanned out to every leaked observer.
  - **Fix:** `NotificationObserverBag`, which removes all its observers when released (like a C++ RAII guard), plus coalesced reachability posts (one per 100 ms). This also removes a main-thread notification storm **in the app itself**.
- **The CI verdict script could never have passed a complete run.** The xcodebuild exit code was masked by `tee`, and the script required exactly "1 issue" while the summary counts known issues too. No run since 9/9 had reached it, because they all timed out first.
- **Hangs fixed tonight, in order:**
  1. Combine memory auto-pause on the 7 GB runner (2d409e75).
  2. The same, in the scan probes (130a630b). PauseGate auto-pause now defaults off inside a test host.
  3. The Integration Stress Vision storm starved the 3-thread task pool (59769e3b). The suite is now skipped on the GitHub virtual M1 (ae57d9cd); it still runs on real Macs.
  4. A TSan-proven race on POIProfile (3d6f95a6). It is not proven to be the macOS-15 hang, so I added a heartbeat watchdog that samples the stack.
  5. The watchdog's first catch, in run 36223041786, was a 255 s search benchmark on the main thread, not a hang.
- **CI-only failures, each with a root cause (442fdc73):**
  - macOS 15 refuses to rename a directory whose own write bit is cleared (the POI fault-injection tests).
  - CI coverage was never real.
  - Speed limits now go through the CI-aware ceiling.
- **Python Tests:** green.
- **Nightly Static Analysis:** red since 9/17. The type-check ratchet fix merged in bb9a7b2f; the next nightly run will confirm it, since no Mac in the fleet has CI's Xcode 26.3.
- **Nightly qwen reviewer:** has reviewed nothing since 9/22. The fix merged in 8a88c5b0, but it **needs you** (below).

## Production bugs found and fixed tonight
- **ProcessRunner** (every ffmpeg/ffprobe call goes through it): lines were delivered outside the read lock, so a command could return before its last output lines were handed over. Now one lock covers read and delivery, and the drain waits out in-flight reads. The test failed every round before the fix.
- **PreviewDiskCache.pruneNow:** two concurrent prunes could delete one extra live preview file. Fixed, with a test.
- **Catalog rename + archive index** (merged yesterday 7b6c7760): its rollback check-then-act is now in the ratchet baseline, and its backup-pruning removals are reviewed in the sensor.
- **POIProfile.ambiguousAnchorsNoted:** data race fixed with a lock.
- **HallieConversationLog:** builds its UTC Calendar once instead of once per event.

## Decisions for Rick (max three)
1. **PauseGate branch `fix/night-qa-pausegate` (pushed, NOT merged).** Pause is now per-reason: user, memory, volume.
   - It fixes: memory relief or a returning drive undoing *your* Pause; Stop hanging behind a paused Person Finder job (#191); a keepalive race.
   - Intended behaviour change: pressing Resume while memory is low or a network drive is gone now *waits*, and the row still says "Scanning".
   - Adversarial QA: MERGE; its follow-ups are fixed. 123 tests green on the M5.
   - Pair it with the silent-auto-pause question: show "Paused — only 2.2 GB free" on the row and in the console? I recommend merging both together.
2. **Local Network permission on the M4 for the nightly reviewer.**
   - Since the macOS 26.7 update (9/22), Homebrew `python3` can't reach the M5's ollama from launchd; curl can.
   - Fix: System Settings → Privacy & Security → Local Network → enable Python (`/opt/homebrew/bin/python3`).
   - If there's no entry, the alternative is `REVIEW_PYTHON=/usr/bin/python3`, which sidesteps the privacy control. That's your call.
3. **Stuck processes (I don't kill processes):**
   - ricksm5: pids 37543 (a test host at 100% CPU) and 37471 (xcodebuild), left from a TSan run. Afterwards remove `/private/tmp/wt-cired4-m5`, `/private/tmp/cired4*`.
   - ricksintel: xcodebuild pid 28178, probably waiting on an authorization prompt on its screen. Afterwards remove `/private/tmp/cigreen-dd` and `~/dev/VideoScan-wt-cigreen` there.

## Full battery (98e1016f)
| Run | Tests run | Failures |
|---|---|---|
| M5, Debug, CI plan | 9,045 | all speed limits under load; pass alone |
| M1, Release | 9,043 | 3 speed limits the M1 is too slow for; pass on the M5 |
| Core `swift test` | 413 + 203 XCTest | speed limits; pass alone |

**No real bugs.** The M1's disk is 98% full (fileproviderd / iCloud busy); worth a look before the next M1 night.

## qwen review
qwen found nothing real in 25 commits, and its one claim was wrong. Everything real came from in-house QA:
- PauseGate ownership (decision 1).
- Worker-slot cancellation (on the branch).
- The blind reviewer (fixed).
- The type-check ratchet (fixed).

## Issues filed tonight
- #190: Promote let an identical file into the archive twice.
- #191: Person Finder Stop while paused (fixed on the branch).
- #192: Combine batches appended mid-run aren't stopped.
- #193: Tests move test POIs into the real `.trash`.

## Not done, and why
- **Refile:** parked by you.
- **Four other readabilityHandler sites** that may share the ProcessRunner race: FFmpegFrameProvider, AllFramesRipper, HallieNeuralSpeech, WhisperWorkerTranscriber. Not audited yet.
- **TriageView O(records) work in the view body (GH #104 class):** noted, not changed.
- **Xcode 26.3 in the fleet:** type-check fixes can't be checked against CI's toolchain until it's installed on the M5.

## Hallie (merged in 365a9b4a)
- **Strict: 51/55** on the branch, or 48/52 counting only questions that existed before tonight (09-18 baseline: 41/44). **Advisory: 608/750**, or 335 on the 09-18 set of 399, which scored 343 then.
- The strict dip on the 09-23 to 09-25 nightlies was mostly the replay loading no family tree. The 9/25 recovery-floor fix restored it.
- **Harvested 11 live turns from 9/21 to 9/24.** Seven fixes, each with a failing test written first:
  - "Christmas videos from 2006" had lost the word Christmas.
  - "thankful pratt and her husband" bound "her" to the wrong person.
  - "tell me about ellen" picked a CyberBrain match over your sister Ellen.
  - Typo repair broke "materanl lines".
  - "how old was dad in 1985" asked for a year.
  - "donna down the cape" searched for a person called "cape".
  - A video question misread as an age question was declined.
- **🔴 ollama updated itself** (0.34.0, then 0.34.2, now 0.34.4) and the translator got worse at filling its slots. **Decision:** pin ollama, or re-baseline on 0.34.4.
- **Contention:** the qwen review lane and the Hallie replay both used the M4's model from 20:48 to 23:19, and every Hallie call timed out, so that first replay was thrown away. Don't schedule them together.
- **Needs your ruling:** CyberBrain has two "Ellen Ronan" records. One points at `@I342486919798@`, which is no longer in the tree, so the which-one prompt shows a raw id.
- **Still open:** strict-036, -042, -044 (red since 9/18); strict-048 (a model-written answer drops the Fort Wagner note); social questions ("who made you") falling through to catalog search.
