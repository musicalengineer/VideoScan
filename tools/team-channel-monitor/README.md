# Team Channel monitor (menu bar)

A menu bar app that shows today's OUTSTANDING `tools/team-channel.py`
messages, one row per message/recipient (who → whom, id, time sent, state).
Answered messages (acknowledged, or a `--reply-to` from the recipient) drop
off the list; the header keeps a count of them.

- **yellow** — not yet answered, under 15 minutes old ("waiting" = not yet
  delivered to the agent's turn, "in progress" = delivered, not acked)
- **red** — not answered after 15 minutes

The menu bar icon shows the outstanding count: `2` = two waiting, `2!` = two
outstanding with at least one unanswered past 15 minutes. Click a row to read the subject and body.
"Tell &lt;agent&gt;" posts a nudge from `rick` (`--reply-to` the stuck message);
"Handled" acks a message addressed to `rick`. Both go through the CLI, so this
app never writes SQLite itself.

```sh
tools/team-channel-monitor/run.sh     # build release + (re)launch
```

Honors `VIDEOSCAN_TEAM_CHANNEL_DB` and `VIDEOSCAN_REPO` (default `~/dev/VideoScan`).
