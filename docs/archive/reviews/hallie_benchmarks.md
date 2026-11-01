# Hallie benchmarks

*Overwritten each time; aggregates only. Per-question answers (family content) stay in the run worktree's `.scratch/bench-logs/`, never in git.*

**How to read this.** Each row is one replay of the 882-turn question set through the headless Hallie shell (Release build, read-only, the real catalog and family tree) against one model. **Strict** (56) holds only model-independent regressions: anything below 56/56 is a bug or a row that belongs in advisory. **Advisory** (826) holds every harvested question with an unreviewed expectation: "clean" means no grader flag, not "verified right". Read it as a before/after signal, not a truth score. Latency is milliseconds from the question to the last answer clause, measured inside the shell on a monotonic clock (new tonight). Median and p90 are nearest-rank.

## Baseline 2026-10-29 (night), Ultra only

Common to every row: Mac **M5 Ultra** (`RicksUltra`, macOS 27.2, Xcode 27.1), Ollama **0.40.12** (not changed by this run; the Ultra was already on 0.40.12 by 14:00 10/29, see Delta), git **1c43dd3f** (branch `bench/hallie-baselines-2026-10-29`), Release binary built from that SHA, live Ultra catalog (schema 13), family tree generation `gen-20261021T211042-60a0`, strict set SHA-256 `373dab9171610850…`, advisory set SHA-256 `1ce2f99c98b2bb07…` (826 = 817 from main + 9 harvested tonight). Models run one at a time; each was unloaded before the next.

### Strict lane (56)

| Run | Model (digest) | Pass / total | Median ms | p90 ms | Failures |
|---|---|---|---|---|---|
| ultra-qwen-r1 | qwen3.8:27b-mlx (`5642e97495e1`, MLX nvfp4) | **56/56** | 86 | 2,514 | none |
| ultra-qwen-r2 | qwen3.8:27b-mlx (`5642e97495e1`) | **56/56** | 86 | 2,560 | none |
| ultra-llama-r1 | llama3.3:70b (`a6eb4748fd29`, GGUF Q4_K_M) | **55/56** | 94 | 6,203 | strict-034: `missing_required_match` (model-phrased presence answer) |

### Advisory lane (826)

| Run | Model | Clean / total | Same 817 as 10/28 | Median ms | p90 ms | Wall s |
|---|---|---|---|---|---|---|
| ultra-qwen-r1 | qwen3.8:27b-mlx | **671/826** | 663/817 | 538 | 1,927 | 712 |
| ultra-qwen-r2 | qwen3.8:27b-mlx | **670/826** | 662/817 | 535 | 1,915 | 693 |
| ultra-llama-r1 | llama3.3:70b | **633/826** | 625/817 | 1,538 | 7,100 | 2,363 |

Flagged turns by category (advisory):

| Category | qwen r1 | qwen r2 | llama r1 |
|---|---|---|---|
| live | 82 | 83 | 98 |
| real_family | 20 | 20 | 21 |
| age_variations | 11 | 11 | 19 |
| family_tree | 10 | 10 | 14 |
| catalog_search | 6 | 6 | 7 |
| typos | 6 | 6 | 7 |
| temporal | 5 | 5 | 1 |
| record_scope | 5 | 5 | 5 |
| biography | 4 | 4 | 5 |
| smalltalk | 2 | 2 | 4 |
| catalog_count | 0 | 0 | 4 |
| identity_capability / edge_cases / grandparent_style / conjunction | 1 / 1 / 1 / 1 | 1 / 1 / 1 / 1 | 3 / 3 / 1 / 1 |
| **total flagged** | **155** | **156** | **193** |

Top flags: `declined_expected_answer` (qwen 96, llama 130), `forbidden_text` (21 / 17), `missing_required_match` (17–18 / 20), `answered_unknowable` (17 / 19), `dead_end_decline` (13 / 16). The 9 new questions: 8/9 clean on every run; all three decline the same one (a public-history biography), and its expectation is still unconfirmed.

### M4: not run tonight
SSH from the Ultra to `ricksm4.local` now refuses the Ultra's key (`Permission denied (publickey…)`). On 10/28 the same command opened the tunnel. So there was no M4 catalog refresh, no M4 harvest and no M4 run. A schema-13 `.backup` of the Ultra catalog was taken at 21:14 (integrity `ok`, `user_version` 13, SHA-256 `a790a9fd…`) and is staged outside git, ready to copy.

## Delta vs 2026-10-28

| | 10/28 | Tonight | Why |
|---|---|---|---|
| Ultra qwen advisory | 654/803 (df65a5bd) | 663/817 · 671/826 | The 803→817 set grew when 14 model-dependent rows moved from strict to advisory (4462e112). Hallie fixes landed too (service attribution e3c764ff, "dad" ≠ Dafydd a1ca573f). Against the last 10/28 run on the 817 set (662/817, a723184a), tonight is +1/0: the same as run-to-run noise (r1 vs r2 differ by 1). |
| Ultra qwen strict | 57–58/67 (old 67-row set) | 56/56 ×2 | The strict set was rebuilt 10/28 (model-independent rows only), and the two real reds (052, 056/057/059) were fixed on main. |
| llama3.3:70b advisory | 604/803 (Ultra and via M4) | 625/817 · 633/826 | Same set change and fixes. llama still trails qwen by ~38 clean turns and is ~3× slower (median 1.5 s vs 0.54 s, p90 7.1 s vs 1.9 s). Its extra flags are mostly declines (130 vs 96). |
| llama strict | 57–58/67 | 55/56 | strict-034's pass depends on the model's own wording of a presence answer, so it fails the strict admission rule. Move it to advisory, or have the composer template that answer (Rick's call, like strict-042/045). |
| "M4" 619/626 | M4's model over an ssh tunnel, Ultra catalog | not run | Tunnel refused tonight. The MLX-numerics-by-chip hypothesis (follow-up 4) is still untested. |
| Ollama | Ultra 0.40.11, M4 0.40.12 | Ultra 0.40.12 (Homebrew symlink dated 10/29 14:00) | The Ultra is now on the M4's version, so follow-up 3 may already hold. M4 not verified tonight. |

## Reproduce

The Release build at the SHA above is in the worktree's `.dd-release`. One run (both lanes) on the Ultra; `REPO` points the harness at the worktree's corpora:

```sh
REPO=/Users/rickb/dev/VideoScan-wt/hallie-baselines-1029 \
LOGDIR=/Users/rickb/dev/VideoScan-wt/hallie-baselines-1029/.scratch/bench-logs \
  bash /Users/rickb/dev/VideoScan-wt/hallie-baselines-1029/scripts/nightly_hallie_replay.sh \
  --bin /Users/rickb/dev/VideoScan-wt/hallie-baselines-1029/.dd-release/Build/Products/Release/VideoScan.app/Contents/MacOS/VideoScan \
  --host http://127.0.0.1:11434 --model qwen3.8:27b-mlx --budget-seconds 9000 \
  --out /Users/rickb/dev/VideoScan-wt/hallie-baselines-1029/.scratch/bench-logs/ultra-qwen-r1.row.json
```

The row JSON carries pass/total, `hallie_<lane>_latency` {n, median_ms, p90_ms}, the SHAs and the tree generation. `scripts/hallie_eval.py grade --run <lane>.json` prints category and flag counts. For llama, swap the `--model` value. Before switching models, unload the old one (`/api/generate` with `keep_alive: 0`).
