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
