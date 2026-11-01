<!-- moved from Claude memory (reference_complexity_counter_source_of_truth) on 2026-10-23; operational reference, rewrite in place -->

Dashboard (metrics/complexity.jsonl via nightly-analysis.yml), the pre-commit/CI gate (scripts/complexity_gate.py vs ci/baselines/complexity_debt.json) and the nightly baseline (scripts/complexity_baseline_nightly.py; "401→398" = entries over CCN 15 OR NLOC 80) all use `measure` in scripts/complexity_metrics.py.

Stock `python -m lizard` is WRONG on this repo: Swift `/…/` regex `|` counted as branches; `get` inside a regex makes a fake getter swallowing the file (HallieLineageQuestion "get" 93, detectShape 88 vs real 42); misses PrunePlan.plan (52). I quoted stock-lizard numbers to Rick on 10/20 and had to retract — don't repeat.

10/20 list: 28 production functions over CCN 30 (all baselined); top = PrunePlan.plan 52 (Core → D). Goal 0 over 30 before the Ultra ([[project_nightly_refactor_and_swift_expert_review]]).
