# Channel Watcher

Local poke system for `docs/team-channel/`. Fixes the "channel is pull-only,
idle agents never see messages" gap — without any cloud round-trip: the poll
watches the channel directory on disk (zero tokens, zero network), and only an
actual new message wakes the addressed agent with a tiny triage-only prompt.

- New `*-claude-*` message → wakes **codex** (`codex exec`, prompt on stdin)
- New `*-codex-*` message → wakes **claude** (`claude -p --model opus` — triage
  doesn't need the top model; the woken agent says so if a full session is needed)
- New `*-rick-*` message → wakes both
- Per-agent cooldown (default 30 min) so a burst of messages is one wake
- Poll every 2 min (config `CHANNEL_POLL_SECONDS`); wake commands overridable
  via `CODEX_WAKE_CMD` / `CLAUDE_WAKE_CMD`

## Install (M4, launchd)

```sh
cp tools/channel-watcher/com.videoscan.channel-watcher.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.videoscan.channel-watcher.plist
```

Logs: `~/Library/Logs/VideoScan/channel-watcher*.log`.
State (seen messages, cooldown stamps): `~/Library/Application Support/VideoScan/channel-watcher/`.

## Manual poke (Rick, when waiting on an agent)

```sh
tools/channel-watcher/watch_channel.sh --poke codex     # or claude
```

Bypasses cooldown; the woken agent reads the channel and replies in-channel.

## Notes

- On (re)start the watcher marks all existing messages as seen — it never
  replays history as wakes.
- Wake prompts are triage-only by design: read the new message, reply
  in-channel or queue the work; never start large tasks from a wake. This keeps
  the token cost of a poke small and predictable.
- The merge-gate review clock (software_dev_policy.md rule 3) is fair once this
  runs: delivery time ≈ posting time.
