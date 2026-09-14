#!/usr/bin/env python3
"""Ratchet: VideoScan never builds a shell command STRING.

The property being pinned
-------------------------
Every external tool in this app is launched through `ProcessRunner`, which
sets `executableURL` plus an arguments ARRAY. That is a `posix_spawn` with a
real `argv[]`: the kernel hands the child its arguments as separate,
already-parsed strings. There is no shell, no word splitting, no glob
expansion — and therefore *no string for an injection to live in*. A path
containing `; rm -rf ~` is just a filename with semicolons in it.

That property is invisible in the code; it is what is ABSENT that protects us.
This checker makes the absence enforceable.

What it flags (all production code only — tests legitimately spawn `/bin/sh`
to synthesise timeouts and signal handling, and are excluded by path):

  shell-invocation   a shell (`/bin/sh`, `/bin/bash`, `/bin/zsh`, `env sh`)
                     launched with `-c`
  shell-interpolated the same, where the command string is built by string
                     interpolation — the actual injection shape
  shell-helper       a new "run this command string for me" helper: a func
                     taking a `command`/`script`/`cmdline` String that spawns
  libc-shell         `system()` / `popen()` from libc
  launch-path        the deprecated `Process.launchPath` API

Second half — the ffmpeg concat demuxer
---------------------------------------
The concat demuxer list file is the one place where our data reaches a parser
we do not control. ffmpeg reads

    file '/Volumes/Media/Donna's birthday.mov'

and a bare apostrophe in a family filename ends the quoted token. The demuxer
requires `'` inside the quotes to be written as `'\\''`. Both writer sites in
`PersonFinderCompilation.swift` do this correctly; this rule pins that.

  concat-unescaped   a `file '...'` list line built by interpolation with no
                     `replacingOccurrences(of: "'", with: "'\\''")` on the
                     interpolated value

Explicitly NOT implemented: "an ffmpeg path argument that could begin with `-`
and be read as an option". Every path this app hands ffmpeg comes from
`URL.path` / `FileManager` / `NSTemporaryDirectory()` and is therefore
absolute, so it cannot be mistaken for a flag — and deciding *statically*
whether an arbitrary interpolated Swift expression yields an absolute path is
not decidable without type information. Any rule I could write here fires on
every `-i`, `\\(path)` in the tree. A checker that cries wolf 200 times a night
trains everyone to ignore the job, which costs more than the bug it hunts. If
this ever needs covering, the right fix is a runtime precondition in the
ffmpeg-arg builder, not a grep.

Memory: one file at a time; nothing accumulates but findings.
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

DEFAULT_BASELINE = os.path.join("ci", "baselines", "subprocess_injection.json")

RULE_DOCS = {
    "shell-invocation":
        "Spawn the tool directly: `ProcessRunner.runProcess(executable: toolPath, "
        "arguments: [...])`. The arguments ARRAY is the whole defence — it is a "
        "posix_spawn argv, so there is no shell to inject into.",
    "shell-interpolated":
        "A command string built by interpolation is THE injection shape. Pass the "
        "interpolated value as its own element of the arguments array instead.",
    "shell-helper":
        "New shell-out helpers bypass ProcessRunner's deadline/kill escalation and "
        "its fd lifecycle as well as reintroducing string commands. Route through "
        "ProcessRunner.",
    "libc-shell":
        "`system()`/`popen()` run `/bin/sh -c`. Use ProcessRunner.",
    "launch-path":
        "`launchPath` is the deprecated string API; set `executableURL` and "
        "`arguments` instead.",
    "concat-unescaped":
        "ffmpeg concat demuxer list lines must escape `'` as `'\\''` — see the two "
        "correct writers in PersonFinderCompilation.swift "
        "(`replacingOccurrences(of: \"'\", with: \"'\\\\''\")`). Without it, a "
        "family filename containing an apostrophe truncates the path and the "
        "compile silently concatenates the wrong media.",
}

SHELL_PATH = re.compile(r'"(?:/bin/(?:sh|bash|zsh|dash|ksh|csh|tcsh)|/usr/bin/(?:sh|bash|zsh))"')
ENV_SHELL = re.compile(r'"/usr/bin/env"')
DASH_C = re.compile(r'"-c"')
ENV_SHELL_ARG = re.compile(r'"(?:sh|bash|zsh)"\s*,\s*"-c"')
LAUNCH_PATH = re.compile(r"\.launchPath\s*=")
LIBC_SHELL = re.compile(r"(?<![\w.])(?:popen|system)\s*\(\s*[\"a-zA-Z_$\\]")
INTERPOLATION = re.compile(r"\\\(")

# A helper that takes a whole command line as one String.
HELPER_PARAM = re.compile(
    r"\b(?:command|cmd|cmdline|commandLine|commandString|script|shellCommand)\s*:\s*String\b"
)
SPAWNS = re.compile(r"Process\s*\(\s*\)|posix_spawn|ProcessRunner\.|\.launch\(\)|\.run\(\)")

ESCAPE_CALL = re.compile(
    r"""replacingOccurrences\s*\(\s*of\s*:\s*"'"\s*,\s*with\s*:\s*"'\\\\''"\s*\)"""
)
# Same call, tolerant of the alternative spelling people reach for.
ESCAPE_CALL_LOOSE = re.compile(r"""replacingOccurrences\s*\(\s*of\s*:\s*"'"\s*,""")

IDENTIFIER = re.compile(r"^[A-Za-z_$][A-Za-z0-9_.$]*$")
LET_BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=")


def _line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def _balanced_interpolation(text: str, start: int):
    """Given index of the `\\(` opener, return (expr, index_after_close)."""
    i = start + 2
    depth = 1
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start + 2:i], i + 1
        i += 1
    return None, len(text)


def check_shell_invocations(rel_path: str, stripped: str):
    """Window-based: a shell path and a `-c` inside the same call site."""
    findings = []
    lines = stripped.split("\n")
    for idx, line in enumerate(lines):
        is_shell = bool(SHELL_PATH.search(line))
        is_env_shell = bool(ENV_SHELL.search(line))
        if not (is_shell or is_env_shell):
            continue
        # Look at the call site: this line plus a small window either side.
        # `executable: "/bin/sh",` / `arguments: ["-c", ...]` sit adjacent.
        lo = max(0, idx - 3)
        hi = min(len(lines), idx + 12)
        window = "\n".join(lines[lo:hi])
        if is_env_shell and not ENV_SHELL_ARG.search(window):
            continue
        if not DASH_C.search(window):
            continue
        # Which line carries the -c payload, and is it interpolated?
        interpolated = False
        for probe in range(idx, hi):
            if DASH_C.search(lines[probe]):
                tail = "\n".join(lines[probe:min(hi, probe + 4)])
                interpolated = bool(INTERPOLATION.search(tail))
                break
        rule = "shell-interpolated" if interpolated else "shell-invocation"
        findings.append(Finding(
            rule=rule,
            path=rel_path,
            line=idx + 1,
            signature=normalise_signature(line),
            message=(
                "shell spawned with -c"
                + (" and an interpolated command string" if interpolated else "")
                + " — VideoScan launches tools with an arguments array, never a "
                  "command string"
            ),
            severity="error",
        ))
    return findings


def check_shell_helpers(rel_path: str, stripped: str):
    findings = []
    for region in split_functions(stripped):
        head = region.lines[0] if region.lines else ""
        # A multi-line signature: scan until the first `{`.
        signature_text = []
        for line in region.lines[:12]:
            signature_text.append(line)
            if "{" in line:
                break
        sig = " ".join(signature_text)
        if not HELPER_PARAM.search(sig):
            continue
        body = "\n".join(region.lines)
        if not SPAWNS.search(body):
            continue
        findings.append(Finding(
            rule="shell-helper",
            path=rel_path,
            line=region.start_line,
            signature=normalise_signature(head + " " + sig[:80]),
            message=(
                f"`{region.name}` takes a whole command line as a String and spawns "
                "— that is a shell-out helper; route through ProcessRunner with an "
                "arguments array"
            ),
            severity="error",
        ))
    return findings


def check_libc_shell(rel_path: str, stripped: str):
    findings = []
    for idx, line in enumerate(stripped.split("\n")):
        if LIBC_SHELL.search(line):
            # `.system(` on an enum case (CaptionRunner's chat roles) is not libc.
            if re.search(r"[\w\)\]]\s*\.\s*system\s*\(", line):
                continue
            findings.append(Finding(
                rule="libc-shell",
                path=rel_path,
                line=idx + 1,
                signature=normalise_signature(line),
                message="libc system()/popen() runs /bin/sh -c; use ProcessRunner",
                severity="error",
            ))
        if LAUNCH_PATH.search(line):
            findings.append(Finding(
                rule="launch-path",
                path=rel_path,
                line=idx + 1,
                signature=normalise_signature(line),
                message="Process.launchPath is the deprecated string API; set executableURL",
                severity="error",
            ))
    return findings


def check_concat_escaping(rel_path: str, stripped: str):
    """Flag `file '\\(x)'` concat-list lines with no `'` -> `'\\''` escaping.

    Requires the literal to START with `file '` so prose that merely mentions a
    file name in quotes (e.g. ArchivistQueryAST's "…naming file '\\(file)'…"
    note) is not a hit.
    """
    findings = []
    regions = split_functions(stripped)
    for match in re.finditer(r'"file\s+\'', stripped):
        lit_start = match.end()
        interp_pos = stripped.find("\\(", lit_start)
        close_quote = stripped.find('"', lit_start)
        if interp_pos < 0 or (0 <= close_quote < interp_pos):
            continue  # fully literal `file '/tmp/x.mov'` — no data, no risk
        expr, _ = _balanced_interpolation(stripped, interp_pos)
        if expr is None:
            continue
        line_no = _line_of(stripped, match.start())
        if ESCAPE_CALL.search(expr) or ESCAPE_CALL_LOOSE.search(expr):
            continue
        # Escaping may have happened on an earlier line: `let escaped = ...`
        expr_head = expr.strip()
        if IDENTIFIER.match(expr_head):
            base = expr_head.split(".")[0]
            region = next((r for r in regions if r.contains(line_no)), None)
            scope = "\n".join(region.lines) if region else ""
            if not scope:
                lines = stripped.split("\n")
                scope = "\n".join(lines[max(0, line_no - 12):line_no])
            escaped_ok = False
            for binding in LET_BINDING.finditer(scope):
                if binding.group(1) != base:
                    continue
                tail = scope[binding.end():binding.end() + 400]
                stop = tail.find("\n\n")
                if stop > 0:
                    tail = tail[:stop]
                if ESCAPE_CALL.search(tail) or ESCAPE_CALL_LOOSE.search(tail):
                    escaped_ok = True
                    break
            if escaped_ok:
                continue
        snippet = stripped[match.start():min(len(stripped), match.start() + 160)]
        snippet = snippet.split("\n")[0]
        findings.append(Finding(
            rule="concat-unescaped",
            path=rel_path,
            line=line_no,
            signature=normalise_signature(f"file '\\({expr_head})'"),
            message=(
                "ffmpeg concat list line interpolates a path without escaping `'` "
                "as `'\\''` — an apostrophe in a filename truncates the path"
            ),
            severity="error",
        ))
    return findings


def scan_text(rel_path: str, source: str):
    stripped = strip_comments(source)
    findings = []
    findings += check_shell_invocations(rel_path, stripped)
    findings += check_shell_helpers(rel_path, stripped)
    findings += check_libc_shell(rel_path, stripped)
    findings += check_concat_escaping(rel_path, stripped)
    findings.sort(key=lambda f: (f.path, f.line, f.rule))
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
    findings.sort(key=lambda f: (f.path, f.line, f.rule))
    return findings


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=".", help="repo root to scan")
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--json-out", default="")
    parser.add_argument("--include-tests", action="store_true",
                        help="also scan test sources (they legitimately use /bin/sh)")
    args = parser.parse_args(argv)

    findings = scan_tree(args.root, production_only=not args.include_tests)
    baseline_path = args.baseline
    if not os.path.isabs(baseline_path):
        baseline_path = os.path.join(args.root, baseline_path)

    if args.update_baseline:
        entries = write_baseline(
            baseline_path, findings,
            note=("Subprocess-injection ratchet baseline. Every entry here is a "
                  "PRE-EXISTING hit, grandfathered in. New hits fail the nightly "
                  "job. Shrink this file, never grow it casually."),
        )
        print(f"Baseline written: {baseline_path}")
        print(f"  {len(entries)} distinct entries, {sum(entries.values())} hits")
        for finding in findings:
            print(f"  {finding.path}:{finding.line}: {finding.rule}: {finding.message}")
        return 0

    baseline = load_baseline(baseline_path)
    new, old = partition(findings, baseline)
    fixed = fixed_keys(findings, baseline)
    report = markdown_report(
        "Subprocess-injection ratchet", new, old, fixed, RULE_DOCS)
    emit(report, args.json_out, new, old)
    set_output("new_count", len(new))
    set_output("pre_existing_count", len(old))
    return 1 if new else 0


if __name__ == "__main__":
    raise SystemExit(main())
