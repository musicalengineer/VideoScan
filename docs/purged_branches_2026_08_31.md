# Branch purge — 2026-08-31

Rick: "clean up the old worktrees and branches so we don't have a lot of
unmerged stuff to track. it should all be on main by the end of the day
unless there was a major problem."

Every SHA below is recorded so nothing is unrecoverable. `git checkout <sha>`
still works after the branch name is gone; the commits stay reachable through
this file and the reflog.

## Merged into main — deleted (`-d`, git verified the ancestry)

| Branch | Tip |
|---|---|
| codex/hallie-regression-sensors-0829 | 7360af04 |
| codex/pronunciation-demo-quality | 1f7c844b |
| codex/session-hardening-candidate | 50ef3b93 |
| codex/session-hardening-integration | 770b1f5b |
| codex/session-regression-additions | f95f731e |
| docs/pronunciation-training-research | 36509559 |
| feature/people-gedcom-simplify | 0c31b3e6 |
| feature/remote-viewer-phase1 | 9d2fb9a7 |
| fix/hallie-pronunciation-reconcile | 15d835c0 |
| fix/hallie-reset-modal-state | 5eb4af2a |
| fix/hallie-teach-typo-exemplars | 4fa368dd |
| fix/media-stream-url-safety | de8ddb09 |
| fix/nightly-two-failures | 8838339e |
| fix/person-photo-perf | f10b1497 |
| fix/remote-viewer-readonly | 95e9954c |
| fix/tree-identity-pin-perf | 1dec5b15 |
| fix/tree-identity-stale-generation | 2792d898 |
| fix/verifier-bare-surname-lead-order | 37298d90 |
| test/catalog-write-observability-hardening | b9052284 |
| test/hallie-live-miss-hardening | fe2732ac |
| test/nightly-gedcom-watchdog | 2a9bbaed |
| test/nightly-sensor-repairs | e2d79589 |
| test/tree-identity-coverage | 40ed109d |

## SUPERSEDED — deleted (`-D`), content verified present in main

These four are not ancestors of main, so git could not confirm them itself.
Each was checked by content before deletion; merging them would have
REGRESSED main rather than added to it.

| Branch | Tip | Evidence it is already in main |
|---|---|---|
| codex/logging-hardening | 16bf5b94 | all 7 `LoggingHardeningTests` present in main verbatim |
| fix/hallie-durable-tree-pin | eda44762 | all 3 executor tests present; main is a strict superset (adds `profileStableID`) |
| feature/family-tree-gedcom | a17d2846 | main replaced that layout with `graph.familyUnits(of:)` + alternating spouse sides |
| feature/hallie-rich-media | 738dcd38 | `FamilyAssetStore` owns path derivation now; `40_Family_Tree` already in 10+ files. The branch's own comment called itself a "stopgap until FamilyAssetStore owns derivation" |

## KEPT deliberately

| Branch | Tip | Why |
|---|---|---|
| fix/ffmpeg-route-parity | 57e8d35a | **The "major problem" exception.** Its own commits say `wip(route-parity) — UNVALIDATED, parked for benchmark`, dated 2026-08-05 and 792 commits behind. Merging unvalidated ffmpeg decode-route changes into main on a tidy-up pass would be reckless; deleting it would throw away work that was parked on purpose. It needs the benchmark it was parked for, and that is Rick's call. |
| metrics | — | Separate lineage (the nightly publishing branch). It has never merged to main and must not. |
