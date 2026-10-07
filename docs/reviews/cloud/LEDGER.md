# Cloud-credit review ledger

Credit: $242 on 2026-10-05, confirmed after C01 (so the local run drew none of it); expires 2026-11-05 02:59 EST; stop at ~$20.

| ID | Date | Cost | Findings (R/NM/N) | Survived Mac verify | Pinned / declined | Report |
|---|---|---|---|---|---|---|
| Stage 0 | 09-29 | ~$8 | 4 REAL | 4 | — | docs/ops/analysis/stage0-*.md |
| C01 | 10-05 | $0 credit (ran locally, ~4 min) | 2 REAL (P2, P3) | 2 of 2 (local qa) | 2 fixed + pinned (59abba93) | branch cloud/C01 |
| C02 | 10-05 | (balance pending) | 9: 8 REAL / 1 NEEDS-MAC, no P1 | 8 confirmed + 1 partly (local qa) | open: GH issue | report on main |
| C03 | | | | | | |
| C04 | 10-06 | (batch: ~$10–15 for 5 sessions per Rick) | 6: 5 REAL / 1 NOISE | 4 confirmed + noise agreed; F5 **P1** | #287 | report on main |

## Nightly program (docs/briefs/cloud/NIGHTLY.md)
Mark a row done by adding it here when its branch is pushed.

| ID | Date | Balance before → after | Findings (R/NM/N) | Survived verify | Applied / declined | Branch |
|---|---|---|---|---|---|---|
| N1006-D-next-refactors | 10-05 | (balance pending) | plan | executed as R2 (local) | in progress | cloud/N1006-D-next-refactors |
| N1007-D-Hallie-rewrite-eval | 10-05 | (balance pending) | evaluation | not yet reviewed | — | cloud/N1007-D-Hallie-rewrite-eval |
| N1007-R-MediaOps-prune | 10-06 | (batch) | 5 REAL | 5 confirmed; F1 **P1** | #287 | report on main |
| N1008-T-Archive | 10-06 | (batch) | 10: 9 REAL / 1 NOISE | 8 confirmed + 1 partly + 1 nit | tests in progress | report on main |
| N1009-D-Core | 10-06 | (batch) | 3 | 2 confirmed + 1 partly; F1 **P1** | #287 | report on main |
| N1010-H-Volumes | 10-06 | (batch) | 7: 6 REAL / 1 NOISE | 6 confirmed | #287 | report on main |

**Balance check 10-06 (Rick):** $214 of $250 left. $242 → $214 = **$28 for 8 sessions** (C02, N1006, N1007-Hallie, N1007-prune, N1008, N1009, N1010, C04): about **$3.50/session**. About 50 findings, 3 P1s confirmed and fixed, 0 refuted by local qa; roughly 1.7 verified findings per dollar.
