"""Check tracked documentation references without dependencies or network access.

The allowlist records exact (source, target) exceptions with a reason; it never
exempts a whole file. Git-history URLs remain historical rather than local links.

Two data files beside this test keep history honest without keeping the files:
tests/docs_retired.txt (the 2026-10-23 reset) and tests/docs_moved.txt (the 2026-11-01
consolidation). Anything under docs/archive/ was deleted on 2026-11-02 (git tag
pre-prune-2026-11-02 holds the last tree with it), so a citation into docs/archive/
is a history pointer, accepted the way the retired list is.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / "tests/docs_links_allowlist.json"
# Deleted 2026-11-02; `git ls-tree -r --name-only pre-prune-2026-11-02 docs/archive` lists
# what was there and `git show pre-prune-2026-11-02:<path>` prints one. Not re-created.
ARCHIVE_PRUNED = "docs/archive"
SUFFIXES = {".md", ".py", ".sh", ".swift", ".yml", ".yaml", ".plist"}
DOC_PATH = re.compile(r"(?<![\w-])docs/[^\s`\"'()\[\],;:#|\\]+")
URL = re.compile(r"(?:https?|file|app|plugin)://[^\s<>]+")
MD_LINK = re.compile(
    r"!?\[[^\]\n]*\]\(\s*(<[^>\n]+>|[^\s)]+)"
    r"|^\s*\[[^\]\n]+\]:\s*(<[^>\n]+>|[^\s]+)", re.MULTILINE
)


def tracked_files(root: Path) -> list[str]:
    return subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=root, text=True
    ).rstrip("\0").split("\0")


def references(source: str, text: str, written_at: str | None = None) -> list[tuple[int, str, str]]:
    """Return (line, citation, root-relative target), including docs Markdown links.

    `written_at` is the path a moved document was written at: its relative links are
    resolved from there, because archived text is kept as written."""
    # Remote URLs (including pinned historical GitHub URLs) are not local paths.
    local = URL.sub(lambda m: " " * len(m.group()), text)
    result = []
    for match in DOC_PATH.finditer(local):
        citation = match.group().rstrip(".}»—–")
        # Angle-bracket template arguments are examples, not literal filenames.
        # Require the static parent directory so a moved template cannot go stale.
        target = citation
        if any(token in target for token in ("<", "${", "$", "{", "*", "?")):
            target = target[:min(target.find(t) for t in ("<", "$", "{", "*", "?") if t in target)]
            target = target.rsplit("/", 1)[0] or "docs"
        result.append((local.count("\n", 0, match.start()) + 1, citation, target))
    if source.startswith("docs/") and source.endswith(".md"):
        for match in MD_LINK.finditer(text):
            citation = (match.group(1) or match.group(2)).strip("<>")
            parsed = urlsplit(citation)
            if parsed.scheme or parsed.netloc or not parsed.path or parsed.path.startswith("/"):
                continue
            target = os.path.normpath(str(Path(written_at or source).parent / unquote(parsed.path)))
            result.append((text.count("\n", 0, match.start()) + 1, citation, target))
    return result


# Sources whose text may not be edited to follow a move: DECISIONS is append-only and STATUS
# belongs to the main session (2026-11-01). Archived documents were kept as written too,
# until the 2026-11-02 prune deleted them.
UNEDITABLE = ("docs/DECISIONS.md", "docs/STATUS.md")
MOVED_FILE, RETIRED_FILE = "tests/docs_moved.txt", "tests/docs_retired.txt"


def historical(target: str) -> bool:
    """A citation into the pruned docs/archive/ tree (tag pre-prune-2026-11-02)."""
    return target == ARCHIVE_PRUNED or target.startswith(ARCHIVE_PRUNED + "/")


def moved_paths(root: Path) -> dict[str, str]:
    """tests/docs_moved.txt: `old path -> where it went`, one per line (2026-11-01)."""
    moved_file = root / MOVED_FILE
    if not moved_file.exists():
        return {}
    pairs = (l.split(" -> ", 1) for l in moved_file.read_text().splitlines()
             if " -> " in l and not l.startswith("#"))
    return {old.strip().rstrip("/"): new.strip().rstrip("/") for old, new in pairs}


def follow_move(target: str, moved: dict[str, str]) -> str | None:
    """The current path of a moved file, or of a file inside a moved folder."""
    target = target.rstrip("/")
    if target in moved:
        return moved[target]
    for old, new in moved.items():
        if target.startswith(old + "/"):
            return new + target[len(old):]
    return None


def missing_references(root: Path, files: list[str], exceptions: dict) -> list[str]:
    missing = []
    retired_file = root / RETIRED_FILE
    retired = set(l.strip() for l in retired_file.read_text().splitlines()
                  if l.strip() and not l.startswith("#")) if retired_file.exists() else set()
    moved = moved_paths(root)
    written_at = {new: old for old, new in moved.items()}
    for source in files:
        if Path(source).suffix not in SUFFIXES and source != "CLAUDE.md":
            continue
        path = root / source
        if not path.exists():
            missing.append(f"{source}: tracked file is missing")
            continue
        kept_as_written = source in UNEDITABLE or source.startswith(ARCHIVE_PRUNED + "/")
        origin = written_at.get(source) if kept_as_written else None
        for line, citation, target in references(source, path.read_text(), origin):
            if (root / target).exists():
                continue
            if target in retired:
                continue  # retired 2026-10-23: in git history (tag pre-reset-2026-10-23); code comments keep old paths
            if historical(target):
                continue  # docs/archive/ pruned 2026-11-02: in git history (tag pre-prune-2026-11-02)
            now_at = follow_move(target, moved) if kept_as_written else None
            if now_at and ((root / now_at).exists() or historical(now_at)):
                continue  # moved 2026-11-01 (tests/docs_moved.txt), then pruned with the archive
            if exceptions.get(source, {}).get(citation):
                continue
            missing.append(f"{source}:{line}: {citation} -> {target}")
    return sorted(set(missing))


def test_tracked_docs_references_exist():
    exceptions = json.loads(ALLOWLIST.read_text())
    assert all(isinstance(reason, str) and reason.strip()
               for targets in exceptions.values() for reason in targets.values())
    missing = missing_references(ROOT, tracked_files(ROOT), exceptions)
    assert not missing, "Missing documentation targets:\n" + "\n".join(missing)


def test_missing_paths_in_all_required_source_types_are_reported(tmp_path):
    files = [f"source{suffix}" for suffix in sorted(SUFFIXES)] + ["CLAUDE.md"]
    for source in files:
        (tmp_path / source).write_text("See docs/missing.md\n")
    assert len(missing_references(tmp_path, files, {})) == len(files)


def test_relative_links_images_and_reference_links_are_checked(tmp_path):
    (tmp_path / "docs/guides").mkdir(parents=True)
    source = "docs/guides/example.md"
    (tmp_path / source).write_text(
        "[missing](../absent.md#details)\n![image](missing.png)\n"
        "[ref]: ../absent.md\n[web](https://example.com/docs/absent.md)\n"
        "[section](#local)\n[ok](example.md)\n"
    )
    missing = missing_references(tmp_path, [source], {})
    assert len(missing) == 3
    assert any("missing.png" in item for item in missing)


def test_allowlist_is_specific_to_source_and_citation(tmp_path):
    for source in ("first.py", "second.py"):
        (tmp_path / source).write_text("docs/retired.md docs/new-missing.md\n")
    missing = missing_references(
        tmp_path, ["first.py", "second.py"],
        {"first.py": {"docs/retired.md": "Historical citation at a retired revision."}},
    )
    assert len(missing) == 3


def test_templates_still_require_the_current_output_directory(tmp_path):
    (tmp_path / "docs/reviews/codex").mkdir(parents=True)
    (tmp_path / "example.py").write_text(
        "docs/reviews/codex/codex-review-<slug>-<date>.md\n"
        "docs/old-reviews/review-<slug>.md\n"
    )
    missing = missing_references(tmp_path, ["example.py"], {})
    assert len(missing) == 1 and "old-reviews" in missing[0]


# ---- docs moved by the 2026-11-01 consolidation (tests/docs_moved.txt) ----
# Fixture paths are built from D and A so this file's own text cites nothing.
D, A = "docs", "docs/" + "archive"


def _moved_tree(tmp_path):
    """A move into a still-present folder (kept/) and one into the pruned archive."""
    (tmp_path / D / "kept/design").mkdir(parents=True)
    (tmp_path / D / "design").mkdir(parents=True)
    (tmp_path / D / "kept/design/old.md").write_text("[sibling](live.md) [gone](nowhere.md)\n")
    (tmp_path / D / "design/live.md").write_text("live\n")
    (tmp_path / "tests").mkdir()
    (tmp_path / MOVED_FILE).write_text(
        "# old path -> where it went\n"
        f"{D}/design/old.md -> {D}/kept/design/old.md\n"
        f"{D}/practices/invariants -> {A}/practices/invariants\n")


def test_moved_paths_resolve_only_in_sources_that_may_not_be_edited(tmp_path):
    """DECISIONS (append-only) and STATUS (the main session's) keep the paths they were
    written with; every other source must cite the new path."""
    _moved_tree(tmp_path)
    sources = [f"{D}/DECISIONS.md", f"{D}/STATUS.md", f"{D}/README.md", "tool.py"]
    for source in sources:
        (tmp_path / source).write_text(
            f"{D}/design/old.md {D}/practices/invariants {D}/practices/invariants/Archive.md\n")
    missing = missing_references(tmp_path, sources, {})
    assert {m.split(":")[0] for m in missing} == {f"{D}/README.md", "tool.py"}
    assert len(missing) == 6


def test_a_moved_entry_whose_destination_is_missing_still_fails(tmp_path):
    _moved_tree(tmp_path)
    (tmp_path / MOVED_FILE).write_text(f"{D}/design/old.md -> {D}/kept/design/absent.md\n")
    (tmp_path / D / "DECISIONS.md").write_text(f"{D}/design/old.md\n")
    assert len(missing_references(tmp_path, [f"{D}/DECISIONS.md"], {})) == 1


# ---- docs/archive/ pruned 2026-11-02 (tag pre-prune-2026-11-02) ----

def test_citations_into_the_pruned_archive_are_historical_in_every_source_type(tmp_path):
    """A path under the pruned archive is accepted as a history pointer — bare paths in
    code and Markdown links in docs alike — while a sibling miss is still reported."""
    (tmp_path / D / "guides").mkdir(parents=True)
    (tmp_path / "tool.py").write_text(f"See {A}/design/old.md and {D}/absent.md\n")
    (tmp_path / D / "guides/g.md").write_text(
        f"[old](../archive/reviews/x.md) [idx](../archive/README.md) `{A}` [gone](../absent.md)\n")
    missing = missing_references(tmp_path, ["tool.py", f"{D}/guides/g.md"], {})
    assert len(missing) == 2 and all("absent.md" in m for m in missing)
    # The prefix is the folder, not a spelling: an "archives" sibling is a real miss.
    (tmp_path / "other.py").write_text(f"{A}s/old.md {A}d.md\n")
    assert len(missing_references(tmp_path, ["other.py"], {})) == 2


def test_a_moved_entry_into_the_pruned_archive_is_historical(tmp_path):
    """DECISIONS cites the pre-consolidation path; MOVED sends it into the archive, which
    the prune deleted: still historical, not a miss."""
    _moved_tree(tmp_path)
    (tmp_path / D / "DECISIONS.md").write_text(f"{D}/practices/invariants/Archive.md\n")
    assert missing_references(tmp_path, [f"{D}/DECISIONS.md"], {}) == []
