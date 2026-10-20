# Desktop work-board trial — 2026-10-20

Rick directs the project from the M4, usually typing to Claude while reading
code, watching metrics, and spot-testing VideoScan. Claude coordinates the
engineering work. Codex supplies independent reviews, QA, tests, and metrics.
Dot calls remain another way Rick can discuss or steer work.

The board is a shared record of assignments, decisions, and evidence. It does
not create replacement Claude/Codex conversations or automatically copy their
conversation histories. The retired local team channel stays retired.

## Start and use it

From the checkout containing this change:

```sh
node tools/engineering-room/scripts/start-board.mjs
```

Open the printed sign-in link. After that, bookmark
`http://127.0.0.1:8766/board`. The metrics page is beside it at `/metrics`.
The default is access from this Mac only. VideoScan uses port 8765; the board
uses 8766 and never restarts or takes over the app's server.

The board separates decisions needing Rick, running work, queued requests, and
recent completions. Codex review cycles are read directly from the existing
`tools/codex_review.py` state. An unavailable file, a stale report, or a dead
review process must remain visibly unavailable or not reporting. A task being
handled does not prove its tests passed or its metrics were published.

## Manager and worker checkpoints

At session start and ordinary work checkpoints, Claude checks the request queue:

```sh
node tools/engineering-room/scripts/board-control.mjs queue --manager claude
```

Codex uses `--manager codex` for work specifically assigned to Codex. This is an
explicit check; no background watcher or terminal integration is implied.
The optional `watch` command prints queue changes but does not execute tasks.
The board shows genuine reports, so an agent which has not connected is not
shown as idle or available.

For a queued request, claim its returned task ID with a session-owned lease:

```sh
node tools/engineering-room/scripts/board-control.mjs resume \
  --manager claude --agent testing --session unique-session-id \
  --task-id task-id-from-queue --progress "Preparing selected tests on M5"
```

For work initiated in the existing Claude session, supply a new stable task ID,
title, and explicit machine (`none`, `m4`, `m5`, or `m1`) on the first report:

```sh
node tools/engineering-room/scripts/board-control.mjs resume \
  --manager claude --agent feature-dev --session unique-session-id \
  --task-id feature-example --task-title "Implement the agreed change" \
  --machine none --progress "Implementation underway"
```

Heartbeat at checkpoints and before the 15-minute lease expires. A blocked
task names the actual blocker; waiting for Rick is explicit. An expired lease
means not reporting, never a fabricated running or finished state.

```sh
node tools/engineering-room/scripts/board-control.mjs heartbeat \
  --manager claude --agent testing --session unique-session-id \
  --state working --task-state working --progress "Tests running on M5"
```

Complete through the existing protocol with the actual outcome, machine,
revision/dirty state, test scope, failures/skips, and links or paths to evidence:

```sh
node tools/engineering-room/scripts/board-control.mjs complete \
  --manager claude --agent testing --session unique-session-id \
  --task-id task-id-from-queue --result-file /path/to/result.md
```

Board mode retains results locally and does not export to the retired channel.
Review cycles already shown automatically should not be registered again as
duplicate review cards. A board outage does not stop authorized engineering
work; report the outage and resume reporting when it is available.

## Metrics and machine use

Metric requests name the machine, revision, and selected measurements. Claude
is the default coordinator. A queued request is not an execution claim; a
completed subset is not whole-suite evidence. Publish only supported sanitized
streams, and distinguish measurement failure from publication failure.

Rick's schedule is documented in `rick-availability.local.md`, timezone
America/New_York: the morning review starts at 11, with interactive development
and spot-testing continuing through the afternoon and evening. M5/M1 are
preferred for long-running work. Typical breaks are not permission to launch
app/UI automation on the M4; require Rick's current quiet-window declaration.

## Trial success

One request goes from queued to a real worker, then to evidence visible beside
the metrics. Rick can tell who owns it, where it is running, whether it needs a
decision, and whether the relevant measurements were updated. Start there
before adding conversation relays or unattended execution.
