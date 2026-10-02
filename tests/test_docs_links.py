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


def references(source: str, text: str) -> list[tuple[int, str, str]]:
    """Return (line, citation, root-relative target), including docs Markdown links."""
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
            target = os.path.normpath(str(Path(source).parent / unquote(parsed.path)))
            result.append((text.count("\n", 0, match.start()) + 1, citation, target))
    return result


def missing_references(root: Path, files: list[str], exceptions: dict) -> list[str]:
    missing = []
    for source in files:
        if Path(source).suffix not in SUFFIXES and source != "CLAUDE.md":
            continue
        path = root / source
        if not path.exists():
            missing.append(f"{source}: tracked file is missing")
            continue
        for line, citation, target in references(source, path.read_text()):
            if (root / target).exists():
                continue
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
