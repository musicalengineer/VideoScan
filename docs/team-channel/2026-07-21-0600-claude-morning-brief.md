---
from: claude
to: rick
cc: codex
re: ☕ Morning brief — everything on main, purge ready for your click
date: 2026-07-21 (overnight of 2026-07-20)
---

## All of today's work is on main and pushed — `7c8fc4f`

- Reachable-only catalog default + honest volume reachability (+ getmntinfo thread-safety)
- Search-hit badge honors the reachable baseline
- ChipInfo single-space
- Gauntlet flows 3 & 5 fixed (macOS-26 `.label`→`.value` quirk)
- **Smart QuickTime/VLC double-click** — QT only when it'll truly play (container + video + audio all QT-reliable), else VLC; unified across Catalog/Archive/People; mini-play button gone, preview kept
- **"Open in VLC" menu item** under "Open in QuickTime Player"
- **Cover-art (`attached_pic`) scanner fix** + boundary tests — new scans classify iTunes cover-art MP3s as audio, not video
- **Purge migration** — see below

Full unit suite was green through the day; the 2 AM nightly `xcodebuild test` runs against this `main` automatically (non-UI, unaffected by the overnight screen lock).

## The purge — ready for your one click
**Catalog ▸ "Purge Cover-Art Music Records…"** (fresh build from main).
- Opens a sheet with a **live recount** (last dry-run: **2,231**, all confirmed cover art — `mjpeg`/`png` fake-video, mostly `.m4p` iTunes purchases; zero real-video false positives).
- QA-verified SAFE (adversarially — the predicate can't match real footage), integration-tested 14/14, safety-polished (Enter won't purge; you must click).
- **A recovery snapshot is written first** (path logged to console). **There is no in-app Undo** — if it ever looks wrong: quit, copy `catalog.pre-coverart-purge.<stamp>.json` over `catalog.json` in `~/Library/Application Support/VideoScan/`, relaunch.
- Files on disk are never touched — only catalog records.

## Gauntlet — honest status
- This afternoon (you present, screen unlocked): flows **2, 3, 5 passed** on the M4 after your TCC grant.
- **Overnight full run did NOT happen:** with the screen locked/asleep, XCUITest can't enable automation mode (exit 3, confirmed twice). UI automation needs an unlocked, awake desktop — it's a "you're-present" activity, not overnight-unattended. **Recommend running the full 5-flow gauntlet this morning while you're at the machine** (`./scripts/run_gauntlet.sh`) — that's also the first real run for flows 1 & 4.

## Your call this morning
1. **Run the purge** (the 2,231) — click when ready; I'll be here.
2. **Spot-test** the smart double-click + "Open in VLC" on real files.
3. Optional: kick the full gauntlet while you're at the keyboard.
4. Branch/worktree cleanup (morning ritual) — say the word once spot-tests pass and I'll purge the merged branches.

Nothing broke, nothing's stuck, and the only destructive action is still behind your click.

— Claude
