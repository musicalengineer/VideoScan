# C03 — Executable: the Python scripts, run and reviewed on Linux

Inherits `docs/briefs/cloud/README.md` with ONE exception: this session may
**run** code (pip install into a venv, pytest, ruff/pyflakes, mypy if quick).
It still changes no source.
Report: `docs/reviews/cloud/C03-python-run-and-review.md`.

## Scope
`scripts/*.py`, `tools/*.py`, and `tests/*.py` (the pytest suite; ~63 files).
Skip anything needing dlib/MLX/torch/GPU or macOS-only commands: list those as
NEEDS-MAC and move on.

## Do
1. Create a venv, install what `requirements*.txt` names (skip heavy ML deps
   if they fail), and run `pytest -q tests`. Report pass / fail / skip / error
   counts and, for every failure, whether it's environmental (Linux, no media)
   or a real defect.
2. Run `ruff check` (or `pyflakes`) over `scripts/` and `tools/`. Triage to
   REAL only: undefined names, unreachable code, a swallowed exception on a
   write path, a `subprocess` call built from an unquoted string.
3. Read the scripts that **write or delete** files (grep for `os.remove`,
   `unlink`, `shutil.move`, `rmtree`, `rename`, `open(...,'w')`) and attack
   the invariant: no script deletes or overwrites media or a catalog/ledger
   file without proving a surviving copy, and none writes outside its stated output dir.
4. `tools/codex_review.py` and the nightly/metrics scripts: do failures surface
   (non-zero exit), or are they masked (`| tail`, bare `except`, exit 0)?
