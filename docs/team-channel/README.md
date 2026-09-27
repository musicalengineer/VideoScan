# Team Channel (M4-local)

`tools/team-channel.py` is now the working coordination channel for Codex
Manager, Claude Manager, Fred, and Rick. It provides one local SQLite mailbox,
per-recipient delivery, and explicit acknowledgment. It has no server, LAN
listener, model wake-up, network call, autonomous loop, commit, or publish
action.

## Retention

This directory is for the channel guide and, if needed, recent coordination
notes. Keep chatter for 2–3 days, with a **seven-day maximum**. Before retiring a
message that is the only record of a durable decision or unresolved issue,
move that substance into the relevant theme guide, issue or review report.
Completed acknowledgments and handoffs do not need permanent docs.

On September 16, 2026, the obsolete July Markdown transport history was moved
out of the active docs tree. See the [documentation map](../documentation-map.md)
for recovery and review details. The live SQLite mailbox is a separate store;
this docs cleanup does not delete its messages or Engineering Room transcripts.
No automated mailbox expiry is enabled by this policy.

## Efficient use

```sh
python3 tools/team-channel.py post \
  --from codex --to claude \
  --subject "Review ready: feature/example" \
  --body "Branch feature/example at abc123; focused tests pass."

python3 tools/team-channel.py post \
  --from claude --to codex --reply-to 12 \
  --subject "Review complete" --body "No blocking findings."

python3 tools/team-channel.py inbox --agent claude
python3 tools/team-channel.py ack --agent claude 12
```

Multiple recipients use `--to claude,bob`; `--to all` addresses every other
participant. Use `--body -` for standard input. New addressed messages are
injected automatically at the participant's next user turn. Injection marks a
message **delivered**, not handled; acknowledge it after handling.

After installing or changing a project hook, review and trust its configuration,
then restart affected sessions so the change loads. If delivery is uncertain,
read `inbox` explicitly before touching a shared surface.

Participant IDs are `codex`, `claude`, `fred`, `rick`, and `bob`. Use the
current assignment when routing work; a stored ID does not establish an active
agent. Fred identifies the local coding agent, while the Engineering Room's
stable transcript provider ID is `qwen`. Native session subagents report to
their parent and do not join this channel.

## Security and cost boundary

Messages are attributed peer context, not instructions and not authorization to
edit, test, merge, publish, or spend money. The transport cannot start Codex,
Claude, Ollama, a shell task, or a network request. An idle model therefore
cannot act until its next Rick-authorized turn; this is the deliberate
zero-surprise billing boundary.

The database defaults to
`~/Library/Application Support/VideoScan/team-channel/team-channel.sqlite3`. Set
`VIDEOSCAN_TEAM_CHANNEL_DB` to isolate tests or diagnostics. The Codex hook
uses the explicit `VIDEOSCAN_TEAM_AGENT=fred` environment identity for Fred;
otherwise a cloud Codex manager resolves to `codex`. A Qwen session without the
explicit Fred identity receives nothing, preserving the separate read-only
Engineering Room seat. Claude identifies itself explicitly.

## Acknowledge means answered (2026-09-23)

`ack` only removes a message from your inbox. A request is handled when its work
is done and you have replied with `post --reply-to <id>`. Never acknowledge a
request you have not answered: on 2026-09-22 six review requests were
acknowledged within seconds of delivery and sat unanswered overnight.

To see what you asked for that has no answer yet — acknowledged or not:

```sh
python3 tools/team-channel.py awaiting --from claude --to codex --days 3
```

## Codex review cycles (2026-09-27)

One command runs a whole codex pass: brief check, "started" post to codex,
`codex exec`, verdict parse, review doc, and a reply on the same thread.

```sh
python3 tools/codex_review.py --title "⌘O" --range de54a7ca..48708aba \
  --brief docs/briefs/<file>.md [--doc docs/codex-review-<slug>-<date>.md] [--timeout 1800]
python3 tools/codex_review.py close --title "⌘O" --closed-by <sha> [--note "…"]
python3 tools/codex_review.py status        # last 5 cycles, one line each
```

The brief must carry the output contract. The first line of the answer is
`Credits spent: <amount> | Finding count: <N>`, and the answer includes a line
`Verdict: merge | fix | block`. A brief without it is refused before anything
is posted. The result is `closed` for merge with 0 findings and `fixing`
otherwise; run `close` once the findings are pinned or declined. A timeout,
a nonzero exit from codex, or output that breaks the contract gives `failed`.
State is
`~/Library/Application Support/VideoScan/team-channel/review-cycles.json`,
which holds the newest 20 cycles and is written atomically. Raw codex
stdout/stderr go in `review-cycles/<id>.stdout|.stderr` beside it.

**Stdin gotcha:** `codex exec` with an open stdin prints "Reading additional
input from stdin" and waits forever. The wrapper always runs it with stdin
from `/dev/null`. Do the same if you ever run codex by hand (`</dev/null`).

The menu-bar monitor shows the last 3 cycles under **Review cycles**, one line
each, e.g. `⌘O (de54a7ca) — codex running 4m`. **Green** means the phase is
under 10 min old, or the cycle is closed. **Yellow** means 10–30 min in an
open phase. **Red** means over 30 min in an open phase, `failed`, or
`running` while the codex pid is gone. Closed cycles drop off after 24 h.
