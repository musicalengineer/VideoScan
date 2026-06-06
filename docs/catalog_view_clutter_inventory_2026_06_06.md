# Catalog view — clutter inventory (for Rick's triage)

Authored 2026-06-06 while you were out, per your note that the catalog tab feels a little busy and we should clean it up.

Nothing was removed. This is a list to consider.

## Toolbar buttons today (top of catalog tab)

1. **Clear** (search) — needed
2. **Correlate** — A/V pair correlation
3. **Duplicates** — duplicate detection
4. **Avid Bins** — you flagged this: "maybe can be implied"
5. **Combine** — A/V combine
6. **Migrate…** — relocate sheet (opens new window)
7. **Stop Combine** — only visible mid-combine; OK
8. **Realtime Scan** — opens realtime detection window
9. **Show CSV** — conditional, OK
10. Search bar — needed
11. **Dossier chip** — new, needed

## Candidates for "imply, don't button" (auto-run instead of buttoning)

| Button | Why it could be implied | Tradeoff |
|---|---|---|
| **Avid Bins** | Per your note, we can detect .avb files near MXFs during scan and process automatically. Result lands in `avid*` fields. | One less manual step; lose the ability to opt out per session. |
| **Correlate** | We could correlate after every scan completes — most scans want A/V pairing anyway. | Slower scan completion; harder to scan-then-stop early. |
| **Duplicates** | Could run after scan completes; populate `duplicateGroupID` etc. | Adds time to scan; same opt-out concern. |

All three are "auto-run after scan completes" candidates. We could keep the buttons for re-run / force-refresh but they wouldn't be the *primary* trigger.

## Candidates for "move to menu / fold under a single ▾"

| Button | Where it could move |
|---|---|
| **Migrate…** | File menu or Window menu (it opens a separate sheet anyway). |
| **Realtime Scan** | Window menu under "Realtime Detection". |
| **Show CSV** | File menu under "Export…" — it's a one-shot reveal in Finder. |
| **Combine / Stop Combine** | Keep prominent — these are core daily actions. |

## Lower priority — things that visually take up space but probably stay

- **Volume header strip** (volume size + media cataloged + Stop button) — high signal, keep
- **View filter menu** + Show removed toggle — keep, but maybe collapse behind a single ▾ icon
- **Row context-menu actions** — Important / Recoverable / Suspected Junk / Junk / Clear Tag / Notes / Find A/V Pair / Combine This Pair / Show in Archive / Show journey / Copy Path / Reveal in Finder / Open in QuickTime — these don't crowd the toolbar (only show on right-click) so probably fine as-is

## Suggested next-step (for your call)

If you greenlight any of these, the cheapest win is **Avid Bins → implied**: scan completion enqueues an Avid-bin pass for any volume with `.avb` neighbors detected, no button needed. We keep the button as "Re-run Avid Bin scan" for the rare manual case but it moves to the Volume menu or context menu where it doesn't crowd the toolbar.
