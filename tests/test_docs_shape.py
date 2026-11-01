"""The shape of docs/ after the 2026-11-01 consolidation (DECISIONS 2026-11-01:
"Docs are consolidated to about 25 live files, about five per major area").

Three guards, each a sensor on the real tree plus unit tests on a poisoned one:
  (a) every docs/design/*.md carries a `Status:` line in its first 15 lines;
  (b) the live Markdown count under docs/ (everything but docs/archive/) is at most
      30 — a ceiling with headroom over ~25, so a new doc is a decision, not drift;
  (c) docs/archive/README.md names every file under docs/archive/ (its path relative
      to that folder), so nothing archived is unexplained.

"Live" counts Markdown only: the .sql schema, the .html renders, the .json/.jsonl data
files and .gitkeep placeholders are artefacts tools read or write, not documents.
Files are listed with git (tracked plus untracked-but-not-ignored), so a git-ignored
convenience copy (the 2026-10-23 zip in Rick's checkout) is neither counted nor
required in the index. Stdlib only.
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
DOCS, ARCHIVE = "docs/", "docs/archive/"
INDEX = ARCHIVE + "README.md"


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


def archive_files_not_indexed(root: Path, files: list[str]) -> list[str]:
    index = root / INDEX
    text = index.read_text(encoding="utf-8") if index.is_file() else ""
    # Named = its path relative to docs/archive/, in backticks (so `a.md` never counts for `xa.md`).
    return [f for f in files
            if f.startswith(ARCHIVE) and f != INDEX and f"`{f[len(ARCHIVE):]}`" not in text]


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
        "subsystem's doc or archive with an index line instead of adding a file:\n  " + "\n  ".join(live))


def test_archive_index_names_every_archived_file():
    files = listed(ROOT)
    assert sum(f.startswith(ARCHIVE) for f in files) >= 100, "the archive looks empty — has it moved?"
    missing = archive_files_not_indexed(ROOT, files)
    assert not missing, ("files under docs/archive/ that docs/archive/README.md does not name "
                         "(add one line: what it was, where its content went):\n  " + "\n  ".join(missing))


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


def test_the_archive_index_must_name_each_file_but_not_itself_or_ignored_ones(tmp_path):
    root = _repo(tmp_path, {
        INDEX: "| `design/named.md` | was | what | went |\n",
        f"{D}/archive/design/named.md": "x",
        f"{D}/archive/design/unnamed.md": "x",
        f"{D}/archive/copy.zip": "x",
    }, ignore=f"{D}/archive/*.zip\n")
    assert archive_files_not_indexed(root, listed(root)) == [f"{D}/archive/design/unnamed.md"]
    (root / INDEX).unlink()
    assert len(archive_files_not_indexed(root, listed(root))) == 2


def test_the_guards_scale_to_ten_thousand_archived_files(tmp_path):
    names = [f"design/f{n:05}.md" for n in range(10_000)]
    files = {ARCHIVE + n: "" for n in names}
    files[INDEX] = "\n".join(f"| `{n}` |" for n in names[:-1])
    root = _repo(tmp_path, files)
    listing = listed(root)
    start = time.monotonic()
    missing = archive_files_not_indexed(root, listing)
    live = live_docs(listing)
    elapsed = time.monotonic() - start
    assert missing == [ARCHIVE + names[-1]] and live == []
    assert elapsed < 5.0, f"{elapsed:.2f} s for 10,000 files (budget 5 s)"
