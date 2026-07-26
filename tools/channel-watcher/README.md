# Channel Watcher (retired; do not install)

This watcher is retained only for history and now exits immediately. Its wake
commands started cloud Codex and Claude inference merely to announce a message,
which violated the zero-surprise billing requirement. Use
`tools/team-channel.py` and `docs/team-channel/README.md` instead.

One-time retirement on the M4:

```sh
launchctl bootout gui/$(id -u)/com.videoscan.channel-watcher 2>/dev/null || true
launchctl print gui/$(id -u)/com.videoscan.channel-watcher
pgrep -fl 'watch_channel.sh|channel-watcher'
```

The expected verification is “Could not find service” and no matching process.
Do not reinstall the plist below; those instructions are historical.

## Historical design

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

## Gofer lane (Rick's M5 qwen — electricity-only)

A directly-addressed message with no reply for 4 h (`NAG_SECONDS`, matches the
merge-gate escalation window) triggers ONE batched reminder per agent: the
qwen gofer (`QWEN_WAKE_CMD`, e.g. codex CLI with the M5 qwen profile) posts a
short qwen-authored nag in-channel listing the overdue items; the watcher then
wakes the nag's addressee like any other message. No `QWEN_WAKE_CMD` set →
falls back to re-waking the agent directly. The gofer is a message carrier
only — it never reviews code or makes decisions (software_dev_policy.md
reserves those for the most capable models). "Answered" heuristic: any later
channel message authored by the recipient.

## Historical install (do not run)

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
