# Nightly adversarial review — design (PROPOSED, 2026-10-01)

Status: **PROPOSED** — awaiting Rick's approval. Author: Claude (Manager) via Plan agent. No code yet.

## Summary
1. A launchd job on the M4 (not GitHub) reviews each day's merges to local `main` — GH never sees unpushed work, and the claude/codex logins live there.
2. Scope = data-risk + truthfulness files touched since the last successful run, pure renames/tests/docs dropped; nothing in scope → one line, exit 0.
3. Per-folder invariants live in `docs/invariants/<Folder>.md` (not in source folders — synced-group/resource clash risk).
4. `tools/adversarial_nightly.py` auto-builds the brief in the #230 brief's shape and output contract; reuses `codex_review.py`'s parser and cycle records.
5. Tier A nightly: headless `claude -p`, Opus 5.5, effort high (xhigh for data-risk), read-only tools, dollar cap.
6. Tier B: codex only for P0/P1 in data-risk folders (≤1/night, ≤4/week) + one bundled Sunday sweep.
7. Every P1/P2 carries a drafted red test; a 05:30 sandboxed scratch worktree runs them and labels each finding `confirmed-red` / `unconfirmed`.
8. Output: untracked review doc + ledger row; after a shadow week, `adversarial-review` issues; a 🔴/🟢/⚪ morning-brief line; Manager closes or declines each finding.
9. Failed nights are never silent: START/OUTCOME log, `failed` phase in review-cycles.json, morning 🔴; findings-per-dollar logged every run.
10. Rollout: shadow 10-02 → 10-08, then filing. Keep/kill = kept P1/P2 per week (closed against a pinning test) + precision.

## 1. Trigger and scope
- **Placement:** two LaunchAgents on the M4, cloned from `com.videoscan.nightly-review.plist` (same PATH, `Nice 10`, log `~/Library/Logs/VideoScan/adversarial_review_launchd.log`):
  - `com.videoscan.adversarial-review` 00:30 — Tier A (cloud-side, light on the M4, done before the 02:00 nightly).
  - `com.videoscan.adversarial-confirm` 05:30 — red tests → Tier B → filing (after `nightly_guarded.sh` ~02:00–03:30 and `nightly_review.sh` 04:30).
  - No M1/M5 failover (they may be asleep/away).
- **Range:** `state/last_sha..main`, baseline advanced only on success (copied from `nightly_review.sh`), so a failed night carries its SHAs forward.
- **Files:** `git diff --name-status -M90% <range>` → drop pure renames (R100; the 09-29 layout move would otherwise flood scope), `*Tests*`, `docs/`, non-Swift → intersect with `paths:` globs in `docs/invariants/*.md`.
- **Buckets:** data-risk (docs/source_layout.md §Data-risk + `CyberBrainWriter.swift`); truth (Hallie answer/executor, date resolution, Core genealogy incl. `Gedcom*`, `*Kinship*`, `LineageTrail`, `LifeAndTimes/`).
- **Load (14-day sample):** 0–5 data-risk and 0–15 truth files/day; about half of nights have something in scope.
- **Gap found:** source_layout did not list `RecordFinderFiling.swift` / `ResearchStore.swift` — where codex found the #230 P1s. Add a pytest sensor `tests/test_invariants_coverage.py`: any Swift file in a data-risk folder that writes via `FileManager` / `write(to:)` / `CyberBrainWriter` must match a glob.

## 2. Auto-generated brief (`tools/adversarial_nightly.py brief`)
- **Invariants files:** `docs/invariants/{Archive,MediaOps,FamilyTree,ArchiveAngelPromote,Volumes,Hallie,Dates,Genealogy}.md` — YAML front matter (`tier`, `paths`), numbered invariants (ARCH-1…), and "Known and accepted (do not report)". Seed from existing briefs (#230's 7 → FT-1..7).
- **Brief sections (order of the #230 brief):** (a) range + merge subjects; (b) files in scope with changed `func` names + "do not explore outside"; (c) callers via `git grep -n -w`, ≤8/symbol, read-only; (d) invariants + known-accepted; (e) already-reported fingerprints (open issues, prior review docs touching the same files); (f) tests already run (latest metrics testdriver row for main + "green" clauses of merge subjects); (g) coverage/logging directive; (h) privacy line; (i) output contract.
- **Output contract:** existing `Credits spent: … | Finding count: N` first line and `Verdict:` line (so `codex_review.parse_output()` / `validate_brief()` work unchanged), plus per finding `### F<n> — P<0-3> — <title>`, `- File:`, `- Invariant:`, `- Key: <path>#<symbol>#<ID>`, and a ```swift red test tagged `// target:` and `// test: Suite/testName`; "read, no findings" per clean file.
- **Size cap:** ≤12 files per brief; split into ≤3 briefs by folder; overflow listed as "NOT REVIEWED" (visible, never dropped).

## 3. Tiering
- **Tier A** (verified: `~/.local/bin/claude` 2.1.287, claude.ai OAuth login; not on launchd PATH → absolute path). cwd = detached scratch worktree at head:
  `~/.local/bin/claude -p --model claude-opus-5-5 --effort high --restricted --tools "Read,Grep,Glob" --strict-mcp-config --permission-mode dontAsk --no-session-persistence --max-budget-usd 10 --output-format json < brief.md` (`--effort xhigh` for data-risk).
  - `--restricted` ignores project settings, so the SessionStart morning hook does not fire at 00:30 and eat Rick's morning digest. No `--bare` (API-key only; this account is OAuth).
- **Tier B:** `tools/codex_review.py --title "adv <date>" --range … --brief <codex brief> --doc docs/adversarial-review/<date>-codex.md --timeout 1800`. Gate: P0/P1 in data-risk; ≤1/night, ≤4/week; Sunday 05:30 bundled weekly sweep if the week touched data-risk. Codex brief = Tier A brief + "claims to confirm or refute (with red-test outcome)" + "find what this reviewer missed".
  - **Policy change needed:** CLAUDE.md's codex spend policy says Rick triggers each pass; gated nightly/weekly passes would need to be pre-approved there (Rick's call).
- **Dedupe:** fingerprint = sha1(path + symbol + invariant ID), no line numbers; `<!-- adv-fp:<hash> -->` in issue bodies; checked against `gh issue list --label adversarial-review --state all`, `docs/adversarial-review/declined.jsonl`, and prior review docs by file+symbol → "dup of #N".

## 4. Output
- **Doc:** `docs/adversarial-review/<YYYY-MM-DD>.md` (header like `write_doc()`: range, tier, model/effort, tokens, notional $, findings by severity, confirmed-red, verdict; then findings, then brief). Written untracked; the Manager commits it with triage decisions — no unattended commits to main. Each run is recorded via `codex_review.new_cycle/update_cycle` for the status line.
- **Issues:** via the nightly findings→issues tool (in progress in parallel) with labels `adversarial-review` + `confirmed-red|unconfirmed`; bodies scrubbed of names, outside paths, transcriptions.
- **Morning brief:** ~15 lines in `.claude/scripts/session_morning_hook.sh` reading `~/Library/Logs/VideoScan/adversarial-review/latest.json`: `🔴 2 P1 (1 confirmed-red), 1 P2 → doc`, `🔴 FAILED: <reason>`, `🔴 did not run`, `🟢 clean, N files`, `⚪ nothing in scope`.
- **Triage:** `adversarial_nightly.py close --fp <h> --test <Suite/test> --sha <fix>` / `decline --fp <h> --reason "…"`.

## 5. Verifying claims (05:30)
- Each drafted test → its own `AdvDraft_<hash8>.swift` in a fresh scratch worktree at head. Core: `swift test --package-path … --filter`. App: one batched `build-for-testing` / `test-without-building -only-testing:VideoScanTests/<Suite>/<test>` with its own derivedData, wrapped in the process-group watchdog lifted from `nightly_local_tests.sh`.
- `confirmed-red` = compiled and failed at an `#expect`/`#require` naming the claim; `unconfirmed` = passed / didn't compile / crashed / timed out (reason recorded).
- **Safety:** static lint rejects drafts mentioning `/Volumes`, `applicationSupportDirectory`, `homeDirectoryForCurrentUser`, `FamilyArchive`, `00_Index`, `Process(`, `URLSession`, or absolute paths outside `temporaryDirectory`; `sandbox-exec` profile `scripts/adversarial/redtest.sb` denies writes to `/Volumes`, App Support/VideoScan, `~/Pictures`, archive roots, and non-loopback network; 10 min/test, 60 min total; skip if `nightly_local_tests.sh` still runs or a `(VideoScan)` exit corpse exists; no UI tests, no app launch; worktree removed, at the latest by 09:30.

## 6. Budgets, stop rules, failures
- Tier A ≤$10/brief notional × ≤3 briefs; 40 min wall clock per brief; Tier B per its caps; all done by 09:30.
- Stop rules: >5 P1 in one run → treat as noisy, skip Tier B, flag; 3 failed nights in a row → self-disable (flag file) + morning 🔴 "disabled".
- START/OUTCOME to `~/Library/Logs/VideoScan/adversarial_review.log` (one sink). Ledger `~/Library/Logs/VideoScan/adversarial-review/ledger.jsonl`: date, range, tier, model, effort, files, tokens, cost/credits, findings by P, confirmed-red, later kept/declined → findings per dollar.
- Failure: `failed` phase, morning 🔴, baseline not advanced; a job that never fires is caught by the missing OUTCOME line.

## 7. Rollout and keep/kill
- Shadow 10-02 → 10-08: doc + ledger + morning line only; no issues, no codex. Turn on filing + Tier B on 10-09 if the shadow docs read sanely.
- Metric (reviewed with the end-of-October codex policy review): kept P1/P2 per week and precision = kept / (kept + declined). Keep at ≥1 kept P1/P2 per week and ≥40% precision; drop to weekly or kill after two zero-kept weeks or precision <25%. Also track later codex/QA misses in files the nightly reviewed.

## Not verified on this machine
- `claude -p` with OAuth under a LaunchAgent (keychain access while locked); `total_cost_usd` meaning on a subscription and weekly-limit accounting; `--restricted` with OAuth; `sandbox-exec` with xcodebuild/SwiftPM (module caches in ~/Library may need allows); findings→issues tool interface (in progress); codex credits (not exposed); whether `.md` in synced groups gets bundled. No headless claude/codex call was made during design.

## Critical files
`tools/codex_review.py`, `tools/model-fitness/nightly_review.sh` (+ its plist), `docs/source_layout.md`, `.claude/scripts/session_morning_hook.sh`, `scripts/nightly_local_tests.sh`, `docs/codex-briefs/230-filing-brief.md`, `docs/codex-review-record-finder-filing-2026-10-01.md`.
