"""Check tracked documentation references without dependencies or network access.

The allowlist records exact (source, target) exceptions with a reason; it never
exempts a whole file. Git-history URLs remain historical rather than local links.
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


# Sources whose text may not be edited to follow a move: DECISIONS is append-only, STATUS
# belongs to the main session, and archived documents are kept as written (2026-11-01).
UNEDITABLE = ("docs/DECISIONS.md", "docs/STATUS.md")


def moved_paths(root: Path) -> dict[str, str]:
    """docs/archive/MOVED.txt: `old path -> where it is now`, one per line (2026-11-01)."""
    moved_file = root / "docs/archive/MOVED.txt"
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
    retired_file = root / "docs/archive/RETIRED.txt"
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
        kept_as_written = source in UNEDITABLE or source.startswith("docs/archive/")
        origin = written_at.get(source) if kept_as_written else None
        for line, citation, target in references(source, path.read_text(), origin):
            if (root / target).exists():
                continue
            if target in retired:
                continue  # retired 2026-10-23: in git history (tag pre-reset-2026-10-23); code comments keep old paths
            now_at = follow_move(target, moved) if kept_as_written else None
            if now_at and (root / now_at).exists():
                continue  # moved 2026-11-01; the index is docs/archive/README.md
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


# ---- docs moved by the 2026-11-01 consolidation (the MOVED.txt in docs' archive) ----
# Fixture paths are built from D so this file's own text cites nothing.
D = "docs"


def _moved_tree(tmp_path):
    (tmp_path / D / "archive/design").mkdir(parents=True)
    (tmp_path / D / "design").mkdir(parents=True)
    (tmp_path / D / "archive/design/old.md").write_text("[sibling](live.md) [gone](nowhere.md)\n")
    (tmp_path / D / "design/live.md").write_text("live\n")
    (tmp_path / D / "archive/MOVED.txt").write_text(
        "# old path -> where it is now\n"
        f"{D}/design/old.md -> {D}/archive/design/old.md\n"
        f"{D}/practices/invariants -> {D}/archive/practices/invariants\n")
    (tmp_path / D / "archive/practices/invariants").mkdir(parents=True)
    (tmp_path / D / "archive/practices/invariants/Archive.md").write_text("x\n")


def test_moved_paths_resolve_only_in_sources_that_may_not_be_edited(tmp_path):
    """DECISIONS (append-only), STATUS (the main session's) and archived text keep the
    paths they were written with; every other source must cite the new path."""
    _moved_tree(tmp_path)
    sources = [f"{D}/DECISIONS.md", f"{D}/STATUS.md", f"{D}/README.md", "tool.py"]
    for source in sources:
        (tmp_path / source).write_text(
            f"{D}/design/old.md {D}/practices/invariants {D}/practices/invariants/Archive.md\n")
    missing = missing_references(tmp_path, sources, {})
    assert {m.split(":")[0] for m in missing} == {f"{D}/README.md", "tool.py"}
    assert len(missing) == 6


def test_archived_relative_links_resolve_against_where_they_were_written(tmp_path):
    _moved_tree(tmp_path)
    missing = missing_references(tmp_path, [f"{D}/archive/design/old.md"], {})
    assert len(missing) == 1 and "nowhere.md" in missing[0]


def test_a_moved_entry_whose_destination_is_missing_still_fails(tmp_path):
    _moved_tree(tmp_path)
    (tmp_path / D / "archive/MOVED.txt").write_text(
        f"{D}/design/old.md -> {D}/archive/design/absent.md\n")
    (tmp_path / D / "DECISIONS.md").write_text(f"{D}/design/old.md\n")
    assert len(missing_references(tmp_path, [f"{D}/DECISIONS.md"], {})) == 1
