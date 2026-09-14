#!/usr/bin/env python3
"""Ratchet: check-then-act against a removable volume.

This is a RELIABILITY rule, not a security one. Nobody is attacking Rick's
Mac Studio. What actually happens is mundane and constant: a USB drive
spins down, a Thunderbolt enclosure drops off the bus, the machine sleeps
mid-copy, SMB times out. Between the moment we ask "does this path exist?"
and the moment we write to it, the entire volume can cease to be there.

    if FileManager.default.fileExists(atPath: dest) { ... }
    ...
    try data.write(to: URL(fileURLWithPath: dest))   // <- volume left

A `fileExists` answer about a removable volume has a shelf life measured in
milliseconds. The write must be the thing that establishes the truth, not a
prior question about it.

The correct pattern already exists in this codebase. `PromoteToArchiveJob`
(see `ArchivePromoteEngine.swift`) opens the destination ONCE, writes, hashes
and fsyncs THROUGH THE SAME DESCRIPTOR into a `.partial`, then
`renameatx_np`s it into place and fsyncs the parent directory. The descriptor
is the reservation: if the volume goes away, the write fails loudly at the
syscall instead of half-succeeding, and a torn `.partial` is never mistaken
for a finished file. Cite that as the fix.

Deliberately NOT a blanket `fileExists` ban. There are 313 `fileExists` calls
in production sources and the overwhelming majority are harmless (probing for
a tool on disk, checking a cache entry, deciding whether to show a button).
Banning them wholesale would produce hundreds of hits nobody would ever read.
The rule requires ALL of:

  1. an existence / attributes / reachability check,
  2. on a path with VOLUME EVIDENCE (a `/Volumes` literal in scope, or a
     volume-shaped identifier),
  3. followed IN THE SAME FUNCTION by a write to a path sharing an identifier
     with the checked one,
  4. where the write does NOT go through an open file descriptor.

Memory: one file at a time.
"""

from __future__ import annotations

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ratchet_baseline import (  # noqa: E402
    Finding, emit, fixed_keys, load_baseline, markdown_report,
    normalise_signature, partition, set_output, write_baseline,
)
from swift_source_scan import (  # noqa: E402
    ROLE_PRODUCTION, classify_source_role, iter_swift_files, split_functions,
    strip_comments,
)

DEFAULT_BASELINE = os.path.join("ci", "baselines", "volume_check_then_act.json")

FIX_TEXT = (
    "Let the write establish the truth: open the destination once, write/hash/"
    "fsync through that same descriptor into a `.partial`, then rename it into "
    "place and fsync the parent directory — the pattern `PromoteToArchiveJob` / "
    "`ArchivePromoteEngine` already uses. A removable volume can disappear "
    "between the check and the write."
)

RULE_DOCS = {
    "volume-check-then-act": FIX_TEXT,
}

CHECK_PATTERNS = [
    (re.compile(r"\bfileExists\s*\(\s*atPath\s*:"), "fileExists(atPath:)"),
    (re.compile(r"\battributesOfItem\s*\(\s*atPath\s*:"), "attributesOfItem(atPath:)"),
    (re.compile(r"\bisWritableFile\s*\(\s*atPath\s*:"), "isWritableFile(atPath:)"),
    (re.compile(r"\bisReadableFile\s*\(\s*atPath\s*:"), "isReadableFile(atPath:)"),
    (re.compile(r"\bcheckResourceIsReachable\s*\("), "checkResourceIsReachable()"),
]

# Writes that create/overwrite a path by NAME. `removeItem` is deliberately
# absent: deleting something that already vanished is the benign direction of
# this race, and `if exists { try? remove }` is everywhere and harmless.
WRITE_PATTERNS = [
    (re.compile(r"\.write\s*\(\s*toFile\s*:"), "write(toFile:)", "arg0"),
    (re.compile(r"\.write\s*\(\s*to\s*:"), "write(to:)", "arg0"),
    (re.compile(r"\bcreateFile\s*\(\s*atPath\s*:"), "createFile(atPath:)", "arg0"),
    (re.compile(r"\bcreateDirectory\s*\(\s*at(?:Path)?\s*:"), "createDirectory(at:)", "arg0"),
    (re.compile(r"\bcopyItem\s*\(\s*at(?:Path)?\s*:"), "copyItem(to:)", "dest"),
    (re.compile(r"\bmoveItem\s*\(\s*at(?:Path)?\s*:"), "moveItem(to:)", "dest"),
    (re.compile(r"\breplaceItemAt\s*\("), "replaceItemAt()", "arg0"),
]

# If any of these appear in the function, the write is descriptor-mediated (or
# journalled through the promote engine) and the check-then-act gap is closed.
DESCRIPTOR_MARKERS = re.compile(
    r"FileHandle|fileDescriptor|FileDescriptor|\bfsync\b|F_FULLFSYNC|"
    r"renameatx_np|\brenamex_np\b|open\s*\(\s*[A-Za-z_$\"]|\bO_CREAT\b|"
    r"ArchivePromoteEngine|\.partial|withUnsafeFileDescriptor|"
    r"copyViaDescriptors|NSFileCoordinator|FileManager\.default\.replaceItem"
)

VOLUME_LITERAL = re.compile(r'"/Volumes')
# Volume evidence is judged on the CHECKED PATH and its provenance, never on
# "some word in this function". An early cut scanned the whole function body
# and promptly called `volumeSnapshots` (a local array of metadata structs)
# and `notifyVolumeAggregatesStale()` volume evidence. Both were nonsense.
VOLUME_IDENTIFIER = re.compile(
    r"(?i)\b\w*(?:volume|mountPoint|mountedPath|externalDrive|driveRoot|"
    r"archiveRoot|destinationRoot|volRoot)\w*\b"
)
# Paths that are, in this app, always somewhere on a catalogued media volume.
VOLUME_PROVENANCE = re.compile(
    r"(?i)\.(?:fullPath|sourcePath|destinationPath|archivePath|mediaPath|"
    r"clipPath|volumePath|mountPoint)\b|\bscanTarget|\bCatalogScanTarget\b|"
    r"\bMasterArchiveDesignation\b|\bdestinationRoot\b"
)

BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]+)?=\s*([^\n]*)")

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
BORING_IDENTS = {
    "fm", "FileManager", "default", "self", "URL", "String", "Data", "path",
    "fileURLWithPath", "atPath", "toFile", "to", "at", "withIntermediateDirectories",
    "contents", "attributes", "options", "encoding", "utf8", "try", "let", "var",
    "if", "guard", "else", "return", "true", "false", "nil", "NSString",
    "appendingPathComponent", "standardizedFileURL", "resolvingSymlinksInPath",
}


def _argument_expressions(text: str, open_paren: int):
    """Return the top-level, comma-separated argument expressions of a call."""
    depth = 0
    args = []
    current = []
    i = open_paren
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            current.append(ch)
            if ch == "\\":
                if i + 1 < len(text):
                    current.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            current.append(ch)
            i += 1
            continue
        if ch in "([{":
            depth += 1
            if depth == 1 and ch == "(":
                i += 1
                continue
            current.append(ch)
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(current))
                return args
            current.append(ch)
        elif ch == "," and depth == 1:
            args.append("".join(current))
            current = []
        else:
            current.append(ch)
        i += 1
    args.append("".join(current))
    return args


def _call_args_after(text: str, match_end: int):
    """Find the enclosing call's `(` for a label match and return its args."""
    open_paren = text.rfind("(", 0, match_end)
    if open_paren < 0:
        return []
    return _argument_expressions(text, open_paren)


def _idents(expr: str):
    return {tok for tok in IDENT.findall(expr) if tok not in BORING_IDENTS}


def _strip_label(expr: str) -> str:
    parts = expr.split(":", 1)
    return parts[1] if len(parts) == 2 else expr


def volume_evidence(expr: str, body: str, max_hops: int = 3):
    """Is the CHECKED path plausibly on a removable volume?

    Walks the local `let`/`var` bindings backwards up to `max_hops` so that
    `newPath <- dir <- oldPath <- record.fullPath` still counts as evidence.
    Returns the evidence string, or None.
    """
    bindings = {m.group(1): m.group(2) for m in BINDING.finditer(body)}
    seen = set()
    frontier = [expr]
    for _ in range(max_hops + 1):
        nxt = []
        for text in frontier:
            if not text or text in seen:
                continue
            seen.add(text)
            if VOLUME_LITERAL.search(text):
                return "/Volumes literal"
            if VOLUME_IDENTIFIER.search(text):
                return "volume-shaped identifier"
            if VOLUME_PROVENANCE.search(text):
                return "catalogued-media path"
            for tok in _idents(text):
                if tok in bindings:
                    nxt.append(bindings[tok])
        frontier = nxt
        if not frontier:
            break
    return None


def scan_text(rel_path: str, source: str):
    stripped = strip_comments(source)
    findings = []
    for region in split_functions(stripped):
        body = "\n".join(region.lines)
        has_volume_literal = bool(VOLUME_LITERAL.search(body))
        descriptor_mediated = bool(DESCRIPTOR_MARKERS.search(body))
        if descriptor_mediated:
            continue

        checks = []   # (offset, kind, expr, idents)
        for pattern, kind in CHECK_PATTERNS:
            for match in pattern.finditer(body):
                args = _call_args_after(body, match.end())
                expr = _strip_label(args[0]).strip() if args else ""
                if not expr and kind != "checkResourceIsReachable()":
                    continue
                checks.append((match.start(), kind, expr, _idents(expr)))

        if not checks:
            continue

        writes = []   # (offset, kind, expr, idents)
        for pattern, kind, which in WRITE_PATTERNS:
            for match in pattern.finditer(body):
                args = _call_args_after(body, match.end())
                if not args:
                    continue
                index = 1 if (which == "dest" and len(args) > 1) else 0
                expr = _strip_label(args[index]).strip()
                writes.append((match.start(), kind, expr, _idents(expr)))

        if not writes:
            continue

        for c_off, c_kind, c_expr, c_idents in checks:
            if not c_idents:
                continue
            evidence = volume_evidence(c_expr, body)
            if evidence is None and has_volume_literal:
                evidence = "/Volumes literal in scope"
            if evidence is None:
                continue
            for w_off, w_kind, w_expr, w_idents in writes:
                if w_off <= c_off:
                    continue
                shared = c_idents & w_idents
                if not shared:
                    continue
                line_no = region.start_line + body.count("\n", 0, c_off)
                findings.append(Finding(
                    rule="volume-check-then-act",
                    path=rel_path,
                    line=line_no,
                    signature=normalise_signature(
                        f"{region.name}:{c_kind}({c_expr})->{w_kind}({w_expr})"),
                    message=(
                        f"`{c_kind}` on `{c_expr}` in `{region.name}` ({evidence}) is "
                        f"followed by `{w_kind}` on `{w_expr}` with no open "
                        f"descriptor between them. {FIX_TEXT}"
                    ),
                    severity="error",
                ))
                break   # one finding per check site is enough
    findings.sort(key=lambda f: (f.path, f.line))
    return findings


def scan_tree(root: str, production_only: bool = True):
    findings = []
    for rel in iter_swift_files(root):
        if production_only and classify_source_role(rel) != ROLE_PRODUCTION:
            continue
        full = os.path.join(root, rel)
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as handle:
                source = handle.read()
        except OSError:
            continue
        findings.extend(scan_text(rel, source))
    findings.sort(key=lambda f: (f.path, f.line))
    return findings


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--json-out", default="")
    parser.add_argument("--include-tests", action="store_true")
    args = parser.parse_args(argv)

    findings = scan_tree(args.root, production_only=not args.include_tests)
    baseline_path = args.baseline
    if not os.path.isabs(baseline_path):
        baseline_path = os.path.join(args.root, baseline_path)

    if args.update_baseline:
        entries = write_baseline(
            baseline_path, findings,
            note=("Check-then-act-on-removable-volume baseline. Pre-existing hits "
                  "only; new hits fail the nightly job. Fix template: "
                  "PromoteToArchiveJob / ArchivePromoteEngine descriptor copy."),
        )
        print(f"Baseline written: {baseline_path}")
        print(f"  {len(entries)} distinct entries, {sum(entries.values())} hits")
        for finding in findings:
            print(f"  {finding.path}:{finding.line}: {finding.signature}")
        return 0

    baseline = load_baseline(baseline_path)
    new, old = partition(findings, baseline)
    fixed = fixed_keys(findings, baseline)
    report = markdown_report(
        "Check-then-act on removable volumes", new, old, fixed, RULE_DOCS)
    emit(report, args.json_out, new, old)
    set_output("new_count", len(new))
    set_output("pre_existing_count", len(old))
    return 1 if new else 0


if __name__ == "__main__":
    raise SystemExit(main())
