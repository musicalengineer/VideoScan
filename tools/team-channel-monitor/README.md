# Team Channel monitor (menu bar)

A menu bar app that shows today's OUTSTANDING `tools/team-channel.py`
messages, one row per message/recipient (who → whom, id, time sent, state).
Answered messages (acknowledged, or a `--reply-to` from the recipient) drop
off the list; the header keeps a count of them.

- **yellow** — not yet answered, under 15 minutes old ("waiting" = not yet
  delivered to the agent's turn, "in progress" = delivered, not acked)
- **red** — not answered after 15 minutes

The menu bar badge is a coloured pill: grey when nothing is outstanding,
yellow `2` = two waiting, red `2!` = two outstanding with at least one
unanswered past 15 minutes. Click a row to read the subject and body.
"Tell &lt;agent&gt;" posts a nudge from `rick` (`--reply-to` the stuck message);
"Handled" acks a message addressed to `rick`. Both go through the CLI, so this
app never writes SQLite itself.

Set **Codex session** to the UUID or exact name of the running Codex session.
**Wake Codex** queues a prompt to that session with the installed `codex queue`
command. **Tell codex** continues to post its normal Team Channel nudge and then
also queues a wake prompt; failures of either operation are shown in the footer.
The target is saved in macOS user defaults. The app invokes Codex directly,
without a shell. Wake requests run off the UI thread, continuously drain bounded
command output, and terminate after five seconds if the CLI does not return.

```sh
tools/team-channel-monitor/run.sh     # build release + (re)launch
```

Honors `VIDEOSCAN_TEAM_CHANNEL_DB`, `VIDEOSCAN_REPO` (default `~/dev/VideoScan`),
and `VIDEOSCAN_CODEX_BIN` (optional direct path to the Codex executable).

Install as a login item (auto-relaunch): `tools/team-channel-monitor/install.sh`
