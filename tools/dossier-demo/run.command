#!/bin/bash
# Dossier demo launcher: double-click it, or `open -a Terminal tools/dossier-demo/run.command`.
# Runs dossier_demo.py on the venv-mlx interpreter (mlx-vlm, mlx-whisper) and keeps the window open.
# Any arguments are passed through (e.g. --n 10 --seed 1234, --files a b c, --skip-models).
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PY="$REPO/venv-mlx/bin/python3"
if [ ! -x "$PY" ]; then
  PY="/Users/rickb/dev/VideoScan/venv-mlx/bin/python3"   # a worktree has no venv of its own
fi
printf '\033]0;VideoScan dossier demo\007'
"$PY" "$HERE/dossier_demo.py" "$@"
status=$?
echo
read -r -n 1 -p "Done (exit $status). Press any key to close this window..."
echo
exit $status
