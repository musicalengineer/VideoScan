# Demo scripts (Rick 2026-11-07, shown to Dan)

- `demo_tour.js` — a slow UI tour of the running app (People, Catalog, folders, Storage, Triage, Archive,
  Family Tree, then a SigLIP 2 Frames search for "a boy playing baseball"), narrated in Hallie's voice.
  `osascript -l JavaScript scripts/demo/demo_tour.js [pace-seconds] [--say] [--only folders|walk|search]`.
  Move the mouse or hold ⌘ to take over. One tour at a time (lock in `.scratch/demo/`). Needs Accessibility
  for osascript. In a Claude Code session, "start demo" runs it.
- `render_voice.py` — renders the narration wavs once (Kokoro, local) into `.scratch/demo/voice/`.
- `hallie_live.py` — runs the E1 questions through Hallie's local tool loop and prints each question, tool call
  and verified answer in colour. `venv/bin/python scripts/demo/hallie_live.py [N] [ollama-tag]`.
