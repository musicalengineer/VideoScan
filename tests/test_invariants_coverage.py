"""Sensor: every file-writing Swift file in a data-risk folder is covered by
an invariants file (2026-10-01, nightly adversarial review design §1).

Why: codex found the #230 P1s in RecordFinderFiling.swift / ResearchStore.swift,
which the source layout guide's data-risk list did not name. The nightly review
only reads files whose path matches a glob in docs/practices/invariants/*.md,
so an uncovered writer is a writer nobody attacks.

Fix a failure by adding a glob (and an invariant, if the file writes
something new) to the right invariants file. Do not narrow WRITE_RE or
DATA_RISK_FOLDERS to make it pass.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import invariants  # noqa: E402

APP = "VideoScan/VideoScan"
CORE = "VideoScan/VideoScanCore/Sources/VideoScanCore"

# docs/guides/source_layout.md, "Data-risk code", plus the CyberBrain writer.
DATA_RISK_FOLDERS = [
    f"{APP}/Archive",
    f"{APP}/MediaOps",
    f"{APP}/FamilyTree",
    f"{APP}/ArchiveAngel/Promote",
    f"{APP}/Volumes",
]
DATA_RISK_FILES = [f"{CORE}/CyberBrainWriter.swift", f"{CORE}/CyberBrainWriter+RootLock.swift"]

# Anything that changes the filesystem. Broader than the design's
# "FileManager / write(to:) / CyberBrainWriter" on purpose: the Archive writes
# through POSIX renames and AtomicFilePublish, not FileManager.
WRITE_RE = re.compile(
    r"\.(?:createDirectory|createFile|moveItem|copyItem|removeItem|trashItem|"
    r"replaceItemAt|replaceItem|linkItem|setAttributes|createSymbolicLink)\("
    r"|write\(to:"
    r"|\bCyberBrainWriter\b"
    r"|\bAtomicFilePublish\b"
    r"|\bappendDurable\b"
    r"|FileHandle\((?:forWritingTo|forWritingAtPath|forUpdating)"
    r"|(?<![\w.])(?:renameatx_np|renamex_np|renameat|unlinkat|unlink|rmdir|mkdirat|"
    r"ftruncate|fchflags|chflags|lchflags)\("
    r"|\bO_CREAT\b|\bO_WRONLY\b|\bO_RDWR\b"
)
# Must stay covered by name (the files the gap was found in).
MUST_COVER = [f"{APP}/FamilyTree/RecordFinderFiling.swift", f"{APP}/FamilyTree/ResearchStore.swift"]


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def writes(path: Path) -> bool:
    return bool(WRITE_RE.search(strip_comments(path.read_text(encoding="utf-8", errors="replace"))))


def writer_files() -> list[str]:
    found = []
    for folder in DATA_RISK_FOLDERS:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            if writes(path):
                found.append(path.relative_to(ROOT).as_posix())
    for rel in DATA_RISK_FILES:
        if (ROOT / rel).exists():
            found.append(rel)
    return found


@pytest.fixture(scope="module")
def files():
    return invariants.load_all()


def test_every_data_risk_writer_is_covered(files):
    writers = writer_files()
    # A sensor that finds nothing is blind, not green.
    assert len(writers) >= 30, f"only {len(writers)} writers found — has the layout moved?"
    uncovered = [rel for rel in writers if not invariants.covering(rel, files)]
    assert not uncovered, (
        "data-risk files that write but no docs/practices/invariants/*.md glob covers:\n  "
        + "\n  ".join(uncovered))


def test_data_risk_writers_land_in_the_data_risk_bucket(files):
    """A writer covered only by a `truth` file would be reviewed at the lower effort."""
    wrong = [rel for rel in writer_files() if invariants.bucket_for(rel, files) != "data-risk"]
    assert not wrong, "data-risk writers bucketed as truth:\n  " + "\n  ".join(wrong)


@pytest.mark.parametrize("rel", MUST_COVER)
def test_the_230_gap_files_are_covered(files, rel):
    assert (ROOT / rel).exists(), f"{rel} moved — update MUST_COVER and the glob"
    assert writes(ROOT / rel), f"{rel} no longer looks like a writer — WRITE_RE regressed?"
    assert invariants.bucket_for(rel, files) == "data-risk"


def test_every_glob_matches_something(files):
    """A stale glob (file renamed or moved) silently covers nothing."""
    tracked = [p.relative_to(ROOT).as_posix() for p in (ROOT / "VideoScan").rglob("*.swift")]
    stale = [f"{f.name}: {pattern}" for f in files for pattern in f.paths
             if not any(invariants.glob_match(pattern, rel) for rel in tracked)]
    assert not stale, "globs that match no Swift file:\n  " + "\n  ".join(stale)


def test_files_are_well_formed(files):
    names = {f.name for f in files}
    assert {"Archive", "MediaOps", "FamilyTree", "ArchiveAngelPromote", "Volumes",
            "Hallie", "Dates", "Genealogy"} <= names
    seen = {}
    for f in files:
        assert f.invariants, f"{f.name} has no numbered invariants"
        assert f.known_accepted, f"{f.name} has no 'Known and accepted' items"
        for inv_id, _ in f.invariants:
            assert inv_id not in seen, f"{inv_id} in both {seen.get(inv_id)} and {f.name}"
            seen[inv_id] = f.name


def test_family_tree_carries_the_230_invariants(files):
    ft = next(f for f in files if f.name == "FamilyTree")
    assert [i for i, _ in ft.invariants[:7]] == [f"FT-{n}" for n in range(1, 8)]


# ---- the matcher itself (the sensor is only as good as its globs) ----

@pytest.mark.parametrize("pattern,path,expected", [
    ("a/**", "a/b/c.swift", True),
    ("a/**", "ab/c.swift", False),
    ("a/*.swift", "a/x.swift", True),
    ("a/*.swift", "a/b/x.swift", False),
    ("a/**/x.swift", "a/x.swift", True),
    ("a/**/x.swift", "a/b/c/x.swift", True),
    ("a/VideoScanModel+Relocate*.swift", "a/VideoScanModel+RelocateQueue.swift", True),
    ("a/File.swift", "a/File.swiftX", False),
])
def test_glob_match(pattern, path, expected):
    assert invariants.glob_match(pattern, path) is expected


def test_front_matter_errors_are_loud(tmp_path):
    bad = tmp_path / "Bad.md"
    bad.write_text("---\ntier: maybe\npaths:\n  - a/**\n---\n")
    with pytest.raises(ValueError):
        invariants.parse_file(bad)
    unclosed = tmp_path / "Unclosed.md"
    unclosed.write_text("---\ntier: truth\npaths:\n  - a/**\n")
    with pytest.raises(ValueError):
        invariants.parse_file(unclosed)
