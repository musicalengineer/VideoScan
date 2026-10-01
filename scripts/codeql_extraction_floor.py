#!/usr/bin/env python3
"""CodeQL Swift extraction floor (GH #171).

For three weeks in August/September the nightly CodeQL job reported "0
alerts" while it extracted 1 of 1,283 Swift files. A green job that scanned
nothing was worse than a red one, because it looked like evidence.

This script counts how many of OUR Swift files the extractor actually
processed. It reads the per-file `swift/diagnostics/successfully-extracted-files`
notifications that codeql-action writes into the SARIF. If that share falls
below a floor, the script exits non-zero and fails the CodeQL job. That is a
broken pipeline, not a finding.

DENOMINATOR: the Swift files the scanned build is supposed to compile. That
is `git ls-files '*.swift'` minus:
  tools/, scripts/, swift_cli/ standalone scripts that are not in any Xcode target
  TestDriver/                  separate Xcode project
  test targets                 VideoScanTests, VideoScanUITests, VideoScanCore/Tests
  executable side targets      VideoScanCore/Sources/videoscan-tree-ingest
                               (a CLI the app scheme does not build)
  vendored checkouts           anything under SourcePackages/, checkouts/, .build/
Test targets are excluded on purpose. CodeQL runs `xcodebuild build`, not
`build-for-testing`, and the extraction step alone already takes ~50 of
the job's minutes. Adding about 930 test files would roughly double that,
for queries aimed at code that ships.

Usage (CI):
    python3 scripts/codeql_extraction_floor.py codeql-results/swift.sarif \
        --floor 0.80 --json-out codeql-coverage.json

Exit codes: 0 = at or above the floor; 1 = below the floor, or the SARIF is
missing or has no extraction diagnostics (fail closed); 2 = usage error.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

EXTRACTED_ID = "swift/diagnostics/successfully-extracted-files"
EXTRACTION_ERROR_ID = "swift/diagnostics/extraction-errors"

# Path prefixes that are not part of the scanned build. See the docstring.
EXCLUDED_PREFIXES = (
    "tools/",
    "scripts/",
    "swift_cli/",
    "TestDriver/",
    "VideoScan/VideoScanTests/",
    "VideoScan/VideoScanUITests/",
    "VideoScan/VideoScanCore/Tests/",
    "VideoScan/VideoScanCore/Sources/videoscan-tree-ingest/",
)
VENDORED_MARKERS = ("/SourcePackages/", "/checkouts/", "/.build/")


def in_scope(path: str) -> bool:
    """True when a tracked .swift path belongs in the denominator."""
    if not path.endswith(".swift"):
        return False
    if path.startswith(EXCLUDED_PREFIXES):
        return False
    wrapped = "/" + path
    return not any(m in wrapped for m in VENDORED_MARKERS)


def tracked_swift_files(repo_root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "*.swift"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def _notification_uri(note: dict) -> str | None:
    for loc in note.get("locations") or []:
        uri = (loc.get("physicalLocation") or {}).get("artifactLocation", {}).get("uri")
        if uri:
            return normalise_uri(uri)
    return None


def normalise_uri(uri: str) -> str:
    """SARIF URIs are repo-relative today. Also accept file:// and runner paths."""
    if uri.startswith("file://"):
        uri = uri[len("file://"):]
    ws = os.environ.get("GITHUB_WORKSPACE")
    if ws and uri.startswith(ws.rstrip("/") + "/"):
        uri = uri[len(ws.rstrip("/")) + 1:]
    marker = "/work/VideoScan/VideoScan/"
    if marker in uri:
        uri = uri.split(marker, 1)[1]
    return uri.removeprefix("./")


def read_extraction(sarif_path: Path) -> tuple[set[str], list[dict]]:
    """Returns (extracted repo-relative paths, extraction-error notifications)."""
    doc = json.loads(sarif_path.read_text(encoding="utf-8"))
    extracted: set[str] = set()
    errors: list[dict] = []
    for run in doc.get("runs") or []:
        for inv in run.get("invocations") or []:
            for note in inv.get("toolExecutionNotifications") or []:
                rid = (note.get("descriptor") or {}).get("id")
                if rid == EXTRACTED_ID:
                    uri = _notification_uri(note)
                    if uri:
                        extracted.add(uri)
                elif rid == EXTRACTION_ERROR_ID:
                    errors.append(note)
    return extracted, errors


def evaluate(tracked: list[str], extracted: set[str], errors: list[dict], floor: float) -> dict:
    scope = sorted(p for p in tracked if in_scope(p))
    hit = [p for p in scope if p in extracted]
    missed = [p for p in scope if p not in extracted]
    error_files = Counter(_notification_uri(e) or "?" for e in errors)
    ratio = (len(hit) / len(scope)) if scope else 0.0
    return {
        "tracked_swift": len(tracked),
        "in_scope": len(scope),
        "extracted_in_scope": len(hit),
        "extracted_total": len(extracted),
        "ratio": round(ratio, 4),
        "floor": floor,
        "ok": bool(scope) and bool(extracted) and ratio >= floor,
        "missed": missed,
        "extraction_errors": len(errors),
        "files_with_extraction_errors": dict(sorted(error_files.items())),
    }


def summary_markdown(result: dict) -> str:
    icon = "✅" if result["ok"] else "❌"
    pct = 100.0 * result["ratio"]
    lines = [
        "## CodeQL extraction coverage (GH #171)",
        "",
        f"{icon} **{result['extracted_in_scope']} of {result['in_scope']}** in-scope Swift files "
        f"extracted ({pct:.1f}%, floor {100 * result['floor']:.0f}%).",
        "",
        f"Tracked Swift files: {result['tracked_swift']}. In scope = app + VideoScanCore sources "
        "(tests, tools, scripts, TestDriver excluded; see scripts/codeql_extraction_floor.py).",
        "",
        f"Extraction errors (file still extracted, AST partial): {result['extraction_errors']} "
        f"in {len(result['files_with_extraction_errors'])} file(s).",
    ]
    if result["missed"]:
        lines += ["", f"<details><summary>Not extracted ({len(result['missed'])})</summary>", "", "```"]
        lines += result["missed"][:200]
        lines += ["```", "", "</details>"]
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("sarif", type=Path)
    ap.add_argument("--floor", type=float, default=0.80)
    ap.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument("--json-out", type=Path)
    ap.add_argument("--tracked-list", type=Path,
                    help="file with one tracked path per line (tests); default: git ls-files")
    args = ap.parse_args(argv)

    if not args.sarif.is_file():
        print(f"::error::CodeQL SARIF not found at {args.sarif}; cannot prove extraction coverage")
        return 1
    tracked = (args.tracked_list.read_text().split() if args.tracked_list
               else tracked_swift_files(args.repo_root))
    extracted, errors = read_extraction(args.sarif)
    result = evaluate(tracked, extracted, errors, args.floor)

    if args.json_out:
        args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    md = summary_markdown(result)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as fh:
            fh.write(md)
    print(md)
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as fh:
            fh.write(f"extracted={result['extracted_in_scope']}\n")
            fh.write(f"in_scope={result['in_scope']}\n")
            fh.write(f"extraction_errors={result['extraction_errors']}\n")

    if not extracted:
        print("::error::SARIF carries no successfully-extracted-files diagnostics; "
              "CodeQL extraction did not run or its diagnostics format changed")
        return 1
    if not result["ok"]:
        print(f"::error::CodeQL extracted {result['extracted_in_scope']}/{result['in_scope']} "
              f"in-scope Swift files ({100 * result['ratio']:.1f}%), below the "
              f"{100 * args.floor:.0f}% floor. The scan is not evidence; fix the build (GH #171).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
