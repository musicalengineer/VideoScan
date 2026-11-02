"""The shape of docs/ after the 2026-11-01 consolidation (DECISIONS 2026-11-01:
"Docs are consolidated to about 25 live files, about five per major area").

Two guards, each a sensor on the real tree plus unit tests on a poisoned one:
  (a) every docs/design/*.md carries a `Status:` line in its first 15 lines;
  (b) the live Markdown count under docs/ is at most 30 — a ceiling with headroom
      over ~25, so a new doc is a decision, not drift.

A third guard (the docs/archive/ index) went with the archive on 2026-11-02: retired
documents are deleted, not kept in the tree; git has them (tag pre-prune-2026-11-02,
and pre-reset-2026-10-23 for the first reset). docs/archive/ is still excluded from
the count in case a file lands there again, so the ceiling cannot be dodged by
re-creating it.

"Live" counts Markdown only: the .sql schema, the .html renders, the .json/.jsonl data
files and .gitkeep placeholders are artefacts tools read or write, not documents.
Files are listed with git (tracked plus untracked-but-not-ignored), so a git-ignored
convenience copy is neither counted nor reported. Stdlib only.
"""
from __future__ import annotations

import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CEILING = 30
STATUS_WITHIN = 15
STATUS_LINE = re.compile(r"^\*{0,2}Status:\*{0,2}\s")
DOCS, ARCHIVE = "docs/", "docs/archive/"  # ARCHIVE: pruned 2026-11-02, still not "live"


def listed(root: Path) -> list[str]:
    """Tracked and untracked-not-ignored files under docs/, that exist on disk."""
    out = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "docs"],
        cwd=root, text=True)
    return sorted({f for f in out.split("\0") if f and (root / f).is_file()})


def live_docs(files: list[str]) -> list[str]:
    return [f for f in files if f.startswith(DOCS) and not f.startswith(ARCHIVE) and f.endswith(".md")]


def design_docs_without_status(root: Path, files: list[str]) -> list[str]:
    missing = []
    for f in files:
        if not (f.startswith("docs/design/") and f.endswith(".md") and f.count("/") == 2):
            continue
        head = (root / f).read_text(encoding="utf-8", errors="replace").splitlines()[:STATUS_WITHIN]
        if not any(STATUS_LINE.match(line) for line in head):
            missing.append(f)
    return missing


# ---- sensors on the real tree ----

def test_every_design_doc_carries_a_status_line():
    files = listed(ROOT)
    assert any(f.startswith("docs/design/") for f in files), "no design docs found — has docs/ moved?"
    missing = design_docs_without_status(ROOT, files)
    assert not missing, (f"design docs with no `Status:` line in their first {STATUS_WITHIN} lines "
                         "(write `Status: built | in flight | parked — <date>. …`):\n  " + "\n  ".join(missing))


def test_live_docs_stay_under_the_ceiling():
    live = live_docs(listed(ROOT))
    assert len(live) >= 6, f"only {len(live)} live docs — the read-first set alone is six"
    assert len(live) <= CEILING, (
        f"{len(live)} live docs under docs/ (ceiling {CEILING}; DECISIONS 2026-11-01). Merge into the "
        "subsystem's doc, or delete it (git keeps it), instead of adding a file:\n  " + "\n  ".join(live))


# ---- the guards themselves, on a poisoned tree ----
# Fixture paths are built from D so the docs-links guard does not read them as citations.
D = "docs"

def _repo(tmp_path: Path, files: dict[str, str], ignore: str = "") -> Path:
    for rel, text in files.items():
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text(text)
    if ignore:
        (tmp_path / ".gitignore").write_text(ignore)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    return tmp_path


def test_a_design_doc_without_status_or_with_it_too_late_is_reported(tmp_path):
    late = "# T\n" + "line\n" * STATUS_WITHIN + "Status: built\n"
    root = _repo(tmp_path, {
        f"{D}/design/ok.md": "# Ok\n\nStatus: in flight — 2026-11-01.\n",
        f"{D}/design/bold.md": "# Bold\n**Status:** built\n",
        f"{D}/design/none.md": "# None\n\nNo status here. Status: inline does not count.\n",
        f"{D}/design/late.md": late,
        f"{D}/design/schema.sql": "-- not a doc\n",
        f"{D}/design/sub/deeper.md": "# not a subsystem doc\n",
    })
    assert design_docs_without_status(root, listed(root)) == [f"{D}/design/late.md", f"{D}/design/none.md"]


def test_the_ceiling_counts_live_markdown_only_and_names_every_file(tmp_path):
    files = {f"{D}/design/d{n:02}.md": "Status: built\n" for n in range(CEILING + 1)}
    files.update({f"{D}/archive/old.md": "x", f"{D}/index.html": "x", f"{D}/design/s.sql": "x",
                  f"{D}/reviews/codex/.gitkeep": ""})
    root = _repo(tmp_path, files)
    live = live_docs(listed(root))
    assert len(live) == CEILING + 1 and f"{D}/archive/old.md" not in live
    (root / f"{D}/design/d00.md").unlink()
    assert len(live_docs(listed(root))) == CEILING


def test_ignored_files_are_neither_counted_nor_listed(tmp_path):
    root = _repo(tmp_path, {f"{D}/design/a.md": "Status: built\n", f"{D}/design/copy.md.zip": "x",
                            f"{D}/notes/scratch.md": "x"}, ignore=f"{D}/notes/\n")
    assert live_docs(listed(root)) == [f"{D}/design/a.md"]


def test_the_guards_scale_to_ten_thousand_files(tmp_path):
    """Scale: 10,000 design docs (one with a late Status line) and 10,000 non-live files
    in the same tree, both guards inside the budget."""
    files = {f"{D}/design/f{n:05}.md": "Status: built\n" for n in range(10_000)}
    files[f"{D}/design/f09999.md"] = "x\n" * STATUS_WITHIN + "Status: built\n"
    files.update({f"{D}/design/renders/r{n:05}.html": "" for n in range(10_000)})
    root = _repo(tmp_path, files)
    listing = listed(root)
    start = time.monotonic()
    live = live_docs(listing)
    missing = design_docs_without_status(root, listing)
    elapsed = time.monotonic() - start
    assert len(live) == 10_000 and missing == [f"{D}/design/f09999.md"]
    assert elapsed < 5.0, f"{elapsed:.2f} s for 20,000 files (budget 5 s)"
