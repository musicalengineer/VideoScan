---
from: claude
to: rick, codex
re: 🗓️ Team standup — 2026-07-21
date: 2026-07-21T11:00-04:00
---

## Health — GREEN
- **main `7c8fc4f`**, in sync with origin.
- **2 AM nightly passed clean against `7c8fc4f`: 2991 passed / 0 failed / 47 skipped** (442s). Yesterday's full stack cleared regression overnight.
- Logic coverage 45.985% (up from ~43.2% — the new feature tests lifted it).

## Shipped since last standup (all merged + pushed to main)
- Reachable-only catalog default + honest volume reachability (+ getmntinfo thread-safety fix)
- Search-hit badge honors the reachable baseline; ChipInfo single-space
- **Smart QuickTime/VLC double-click** (QT only when it'll truly play; else VLC) — unified across Catalog/Archive/People; mini-play removed, preview kept
- **"Open in VLC"** context-menu item under "Open in QuickTime"
- **Cover-art (`attached_pic`) scanner fix** + boundary tests — iTunes cover-art MP3s classify as audio, not video, on new scans
- Gauntlet flows 3 & 5 fixed (macOS-26 `.label`→`.value` quirk)
- **Purge migration** — QA-safe, integration-tested 14/14, safety-polished, merged; INERT until Rick clicks

## Needs Rick (this session)
1. **Run the purge** — Catalog ▸ "Purge Cover-Art Music Records…"; live recount (~**2,231**, all confirmed cover art); recovery snapshot auto-saved, no in-app undo (restore-from-snapshot documented). NOT yet run.
2. **Spot-test** smart double-click + Open-in-VLC on real files.
3. **Full gauntlet** — run while you're at the keyboard (first real run of flows 1 & 4). It CANNOT run unattended overnight — UI automation needs an unlocked/awake desktop (confirmed: locked screen → exit 3). It's a "Rick-present" activity from now on.
4. **Branch/worktree purge** (morning ritual) — say the word once spot-tests pass; several merged branches + worktrees ready to clean.

## Open issues
- **Nightly metrics bug (codex's surface):** `nightly_local_tests.sh:98 quality_flag[@]: unbound variable` still fires → person-eval/POI metrics publish as `collector-failed` (red band). Unit suite is unaffected, but the person-recognition metrics haven't published for 2 nights. Bash-3.2 empty-array expansion — same class as the gauntlet-runner fix. Codex, can you take this?

## Coordination / machine notes
- UI automation (gauntlet) = Rick-present, screen-unlocked only. Non-UI (builds, unit tests, nightly) run fine unattended.
- No codex channel activity overnight; C3 remains the POI baseline (C5 failed its gate).

— Claude
