#!/usr/bin/env python3
"""Fail fast when a NEW test file has no stage in scripts/gauntlet/manifest.json.

Why (2026-10-06): the gauntlet refused to run — every stage BLOCKED — because
103 test files had been added since the manifest was last touched on 10/2.
Nothing said so at commit time; the drift surfaced only when the away-window
run started. This is the cheap early warning; the gauntlet's own
`inventory.swift --validate` stays the authority (it also checks declaration
lists, suites, selectors and floors, which this script deliberately does not).

File rules mirror `discover()` in scripts/gauntlet/inventory.swift:
  * Swift: path contains "Tests/" and the file declares at least one test
    (`@Test … func name(` or `func test…(`, comment lines ignored);
  * Python / shell: stem starts with `test_` or ends with `_test`;
  * hidden entries and build/venv/fixture/trash folders are skipped.

Usage:
  manifest_drift.py --staged [--root DIR]   pre-commit: files ADDED in the index
  manifest_drift.py --all    [--root DIR]   CI: every test file in the tree

Exit 0 when every checked file is assigned, 1 otherwise. No network; < 1 s.
"""
import argparse
import json
import os
import re
import subprocess
import sys

MANIFEST = 'scripts/gauntlet/manifest.json'
SKIP_DIRS = {'.build', '__pycache__', 'fixtures', 'venv', 'node_modules',
             'DerivedData', 'build', '.trash'}
_COMMENT_LINE = re.compile(r'(?m)^\s*//.*$')
_SWIFT_TEST = re.compile(r'@Test\b[\s\S]*?\bfunc\s+[A-Za-z_][A-Za-z_0-9]*\s*\(')
_XCTEST = re.compile(r'\bfunc\s+test[A-Za-z_0-9]*\s*\(')
HOW = ('assign it a stage in scripts/gauntlet/manifest.json (docs/guides/gauntlet.md), then run '
       'swift scripts/gauntlet/inventory.swift --validate . scripts/gauntlet/manifest.json')


def is_test_path(path):
    """True when the path's NAME makes it a candidate (content checked separately)."""
    name = os.path.basename(path)
    stem, ext = os.path.splitext(name)
    if ext == '.swift':
        return 'Tests/' in path
    if ext in ('.py', '.sh'):
        return stem.startswith('test_') or stem.endswith('_test')
    return False


def skipped(path):
    """Mirror of the enumerator's pruning: hidden components and skip folders."""
    parts = path.split('/')
    return any(p.startswith('.') or p in SKIP_DIRS or p.startswith('venv-') for p in parts[:-1]) \
        or parts[-1].startswith('.')


def declares_tests(path, text):
    if not path.endswith('.swift'):
        return True
    cleaned = _COMMENT_LINE.sub('', text)
    return bool(_SWIFT_TEST.search(cleaned) or _XCTEST.search(cleaned))


def is_test_file(path, text):
    return is_test_path(path) and not skipped(path) and declares_tests(path, text)


def assigned_paths(manifest_text):
    return {a.get('path') for a in json.loads(manifest_text).get('assignments', [])}


def unassigned(candidates, assigned):
    """candidates: iterable of (repo-relative path, text). Returns sorted misses."""
    return sorted(p for p, text in candidates if p not in assigned and is_test_file(p, text))


def _read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return ''


def walk_tree(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if not d.startswith('.') and d not in SKIP_DIRS and not d.startswith('venv-')]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if is_test_path(rel) and not name.startswith('.'):
                yield rel, _read(root, rel)


def _git(root, *args):
    return subprocess.run(['git', '-C', root, *args], check=True, capture_output=True).stdout


def staged_added(root):
    out = _git(root, 'diff', '--cached', '--name-only', '--diff-filter=AR', '-z')
    for rel in filter(None, out.decode().split('\0')):
        if is_test_path(rel):
            yield rel, _git(root, 'show', ':' + rel).decode('utf-8', 'replace')


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--staged', action='store_true')
    mode.add_argument('--all', action='store_true')
    ap.add_argument('--root', default='.')
    args = ap.parse_args(argv)
    root = os.path.abspath(args.root)
    if args.staged:
        try:  # the STAGED manifest is what the commit will carry
            manifest_text = _git(root, 'show', ':' + MANIFEST).decode()
        except subprocess.CalledProcessError:
            manifest_text = _read(root, MANIFEST)
        candidates = staged_added(root)
    else:
        manifest_text = _read(root, MANIFEST)
        candidates = walk_tree(root)
    if not manifest_text:
        print(f'gauntlet manifest: {MANIFEST} not found under {root}', file=sys.stderr)
        return 1
    misses = unassigned(candidates, assigned_paths(manifest_text))
    for path in misses:
        print(f'gauntlet manifest: new test file {path} has no stage — {HOW}', file=sys.stderr)
    return 1 if misses else 0


if __name__ == '__main__':
    sys.exit(main())
