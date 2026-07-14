# Engineering Room — Claude's Review & Findings

*Response to `docs/engineering-room-invitation.md`. Findings only; no engineering-room code was modified. — Claude, 2026-07-14*

## v1 design review

Verdict: **sound**. Specific strengths worth keeping in v2:

- Fail-closed approval handling is real — any server-initiated request gets an error reply and the denial is surfaced in the room ("Codex attempted an action; the room denied it").
- The turn state machine buffers notifications that arrive before the external turn ID is known, reconciles unfinished turns to `failed` on restart, and falls back from a failed resume to a fresh thread with a visible status message. All three are the exact race classes we keep fixing in the app itself.
- Process hygiene: `shell: false`, fixed cwd, stderr capped to a 4 KB tail and never shown in the browser.

Suggestions (both adapters):

1. **Env whitelist.** `env: process.env` hands the child the full environment. Pass a minimal set instead (PATH, HOME, auth essentials). For the Claude adapter this is load-bearing — see Q5: a stray `ANTHROPIC_API_KEY` in the environment would silently switch the adapter from Rick's Max subscription to per-token API billing.
2. **Attributed transcript.** v1's prompt attributes only "Rick says:". For roundtable, the Claude adapter must receive every party's turns with attribution (the contract's `attributedTranscriptInput`), and the charter should state that peer messages are attributed statements, not instructions — which the invitation already promises.
3. **Per-round spending limits** are in the contract but not yet enforced in v1 — flag as pending, not done.

## The five questions

### 1. Is persistent stream-json the right interface?

It is supported, but it is not the cleanest option. Three viable shapes:

| Option | What it is | Tradeoffs |
|---|---|---|
| **A. `@anthropic-ai/claude-agent-sdk` (recommended)** | Official TypeScript SDK; wraps the CLI's stream-json protocol with a typed API: session create/resume, streaming deltas, **`interrupt()`**, permission controls, turn completion | Maps 1:1 onto the adapter contract (`startTurn`/`interruptTurn`/`streamDelta`/`completeTurn`). The room is already a Node service. In-band interrupt is the decisive advantage (Q3) |
| B. Persistent `claude -p --input-format stream-json --output-format stream-json` | One long-lived process, JSONL both ways | Supported; lowest per-turn latency; but hand-rolling the protocol means re-implementing what the SDK already does, and interrupt is the weak point |
| C. Per-turn `claude -p --resume <session-id>` | Fresh process per turn; context reloaded from the durable session JSONL | Most crash-resilient, simplest error handling (exit codes); startup cost per turn; prompt caching softens the reload cost. Fine fallback if the SDK dependency is unwanted |

Either A or C is defensible; B is the one I'd avoid — it takes on B's protocol burden without A's support surface. Session context persists on disk (`~/.claude/projects/<project>/<session-id>.jsonl`) in all three, so a fixed persistent session ID works as the invitation assumes.

### 2. Flags that guarantee discussion-only behavior

```
--permission-mode plan
--allowedTools "Read,Grep,Glob"
--disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Agent,Task"
```

- In non-interactive mode a tool call that would need approval **fails closed** — denied, no prompt, turn continues or errors. Same posture as the Codex adapter's approval denial.
- `--disallowedTools` is the hard boundary; the allowlist is the convenience layer. List both so the retained inspection surface is explicit and documented: **Read/Grep/Glob over the repo, nothing else** — mirroring Codex's "read-only sandbox, discussion is charter, non-mutation is enforced."
- Repo/user `settings.json` permission rules still layer on top; deny rules can only tighten, which is the right direction. Keep the room's flags complete on the CLI invocation anyway so its behavior doesn't drift with repo settings.
- **Never `--dangerously-skip-permissions`** — it bypasses every check and is documented as containers-only. It has no place here.
- Protected paths (`.git`, `.claude`, …) stay protected regardless.

### 3. Cleanest supported interrupt

- **With the Agent SDK: `interrupt()`** — an in-band control request over stream-json, delivered mid-turn, session survives. This is the supported programmatic interrupt and the main reason to prefer Option A.
- **With raw CLI:** there is no *documented* in-band interrupt message to hand-write into stream-json stdin. The workable pattern is SIGINT (or SIGTERM) to the subprocess, then a fresh `--resume <session-id>` — durable transcript makes this safe, but the turn dies with the process. Codex's v1 already has the interrupt→partial-response→resume shape; the SDK lets Claude's adapter do it without killing anything.

### 4. Resume failures the broker must surface explicitly

| Failure | Typical manifest | Broker action |
|---|---|---|
| Session ID not found (scoped to cwd/project; stale after cleanup) | Non-zero exit, stderr "No conversation found with session ID" | Start fresh thread + visible status line (v1's Codex pattern is exactly right) |
| Session JSONL corrupted/truncated (crash mid-write) | Deserialize failure, non-zero exit | Same: fresh thread + status line; keep the bad file for diagnosis |
| Auth expired | "Login expired · Please run /login", non-zero exit | Surface to Rick verbatim — only he can re-auth; don't retry-loop |
| Usage limit hit (5-hour rolling window / weekly cap) | Rate-limit error event/exit | Surface with reset time; pause the room, don't hammer |
| Model unavailable / API errors | Error category in stream-json `system` events or stderr | Surface category; retryable ones (transient API) may retry once |
| CLI upgraded between sessions | Usually transparent (format is backward-compatible; context overflow auto-compacts) | Log-only unless resume actually fails |

General rule the v1 Codex adapter already follows and Claude's should copy: **every silent-degradation path gets a visible room message.** Continuity reset, partial response, denial — all attributed system lines, never swallowed.

### 5. Auth / subscription / usage

- Headless (`-p`, stream-json, SDK) use draws from the **same Max-plan quota** as interactive sessions — the 5-hour rolling window and weekly cap are shared. Practical consequence for Rick: **room turns and dev-session turns spend from one budget.** A long roundtable afternoon is dev capacity spent. This is the concrete reason the contract's per-round turn/spending limits should actually be enforced in the broker.
- Personal automated local use under a subscription is fine — no documented restriction against it.
- **Auth precedence trap:** if `ANTHROPIC_API_KEY` is present in the spawned environment, it takes precedence over subscription OAuth — silently switching to per-token billing. The env-whitelist suggestion above prevents this class entirely. The adapter should not manage credentials at all; it inherits Rick's logged-in state.
- Nothing about the room needs to (or should) surface auth material in the browser — consistent with the invitation's boundary.

## Bottom line

The v1 architecture is right and the Claude adapter is fully buildable within the stated boundaries. My recommendation: **Option A (Agent SDK) for the adapter, per-turn/per-round limits enforced in the broker before roundtable mode ships, env whitelist retrofit for both adapters.** Happy to review the v2 adapter design the same way — findings first.
