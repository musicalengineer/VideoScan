# Jim — a modular local gofer for VideoScan

Jim is a supervised junior assistant: a small **local** LLM (Qwen on the M5 Pro) that
Claude/Codex delegate bounded grunt work to, and always verify. Free to run, private,
no rate limits. For the hard 5% he can't do, he escalates to a cloud brain.

Design goal: **modular**. An "employee" is just a name + a config file + a persona file.
Swapping the model, or replacing Jim with Bob, is a config change — never a rewrite.

## Quickstart
```bash
# 1. On the M5 Pro, serve a model on the LAN:
OLLAMA_HOST=0.0.0.0:11434 ollama serve &
ollama pull qwen3:30b-a3b

# 2. From anywhere that can reach ricksm5.local, talk to Jim:
tools/jim/bin/jim "List which of these are video files: a.mov b.txt c.mkv d.pdf e.mp4"

# Inspect the request without sending it:
tools/jim/bin/jim --dry-run "test task"

# Use the cloud brain for a hard one:
tools/jim/bin/jim --escalate "Summarize the tradeoffs in this design note: ..."
```

## Layout
| Path | Purpose |
|------|---------|
| `bin/gofer.sh` | The engine — employee-agnostic. Selects the employee from the invoked name. |
| `bin/jim` | Symlink to `gofer.sh`; `jim "..."` runs employee `jim`. |
| `config.sh` | Shared defaults (host, port, temperature, timeout). |
| `employees/<name>.conf` | Per-employee brain, endpoint, params. |
| `personas/<name>.md` | Per-employee job description (system prompt). |
| `DELEGATION.md` | Policy Claude/Codex follow to hand off + verify. |
| `eval/` | Audition tasks + rubric to prove a hire before trusting it. |

## Audition a different brain (same role)
Edit `MODEL` in `employees/jim.conf`, then run the eval (below) to compare.

## Hire a new employee (e.g. Bob)
```bash
cd tools/jim
cp employees/jim.conf employees/bob.conf   # edit MODEL / params
cp personas/jim.md    personas/bob.md       # edit the job description
ln -s gofer.sh        bin/bob
bob "some task"
```
That is the whole "try Jim, then Bob, then …" workflow: each candidate is a real
command backed by its own config, sharing one engine.

## Prove the hire before you trust it
```bash
tools/jim/eval/run_eval.sh jim        # runs eval/tasks.jsonl through Jim, saves outputs
# then grade eval/out/jim/*.txt against eval/rubric.md (by eye or hand to Claude)
```
The eval deliberately includes **traps** (out-of-scope + missing-context tasks) to check
Jim refuses instead of bluffing — the failure mode that got Fred let go.

## Flags
`--employee NAME` · `--escalate` · `--dry-run` · `--raw` · `-h`
