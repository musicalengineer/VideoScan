#!/usr/bin/env python3
"""Nightly OVER-EXPOSURE metric: internal declarations that need not be.

Why this exists
---------------
Rick (2026-10-07): catch "it's easier this way for now". A helper is left
internal (Swift's default) because that was the quickest thing that compiled,
or a type is split across `T+Feature.swift` files and its privates are widened
to internal so the other files can see them. Nothing measured either; this
does, every night, report only.

What it measures
----------------
Every declaration in app code (VideoScan/VideoScan, VideoScan/VideoScanCore/
Sources, swift_cli; the same file list and folder buckets as
scripts/complexity_metrics.py) whose access is internal, written or by
default: func, var, let, init, subscript, nested struct/class/enum/actor, and
top-level func/var/let. Skipped:

  * public / open / package / private / fileprivate (and every member of a
    private or fileprivate type, a `private extension` or `public extension`);
  * `override`, protocol requirements, `@objc` / `@objcMembers` scopes,
    `@IBAction` / `@IBOutlet` / `@NSManaged`, `@main` and `main`;
  * SwiftUI `body`, nested `CodingKeys`;
  * likely protocol WITNESSES (a witness may not be private): any name that
    is a requirement of a protocol declared in this repo, a fixed list of
    system witness names (`id`, `description`, `hash`, `makeNSView`, …), more
    such names when the enclosing scope declares a conformance (`encode`,
    `reduce`, `next`, …), and functions whose first parameter is an Apple
    framework class (`_ tableView: NSTableView`: a delegate method);
  * local declarations (anything inside a function, closure or accessor) and
    local types;
  * one-file scripts (a `#!` first line, as swift_cli's tools are): in a
    program of one file, private buys nothing. Their lines still count.

For each declaration, every file of the same MODULE that mentions its name
(as an identifier token, so `.name`, `name(`, `\\.name` and argument labels all
count; comments stripped, string literals kept) is a reference. The module's
`@testable` tests count as references too: a declaration the tests reach
cannot be made private without breaking them. An `init` is referenced through
its type's name; a `subscript` cannot be resolved by name and is always fine.

Classification:

  could-be-private   referenced only in its own file
  widened-for-split  referenced outside its own file, but only from files that
                     extend the SAME type: `T.swift` / `T+*.swift` declaring
                     `extension T` (or T itself); T is the outermost enclosing
                     type
  fine               anything else

Name collisions: a reference is a token, so another type's member of the same
name in another file reads as a reference. That only ever moves a declaration
toward "fine" (conservative). Widened-for-split is the only class a collision
could invent, so a short or common name (< 4 characters, or in > 50 files of
the module) is never widened-for-split: it counts as fine.

Outputs
-------
  --row-out    one JSONL row (metrics/exposure.jsonl): totals, per folder, top
               20 files by could-be-private count, ratchet counts
  --files-out  the per-file map (metrics/exposure_files_latest.json): lines,
               declarations, and the names in each over-exposed class
  --new-out    NEW over-exposed declarations (metrics/exposure_new_latest.json):
               the morning digest prints them as 🔴 (`--alert`)

The ratchet (REPORT ONLY; no commit gate)
-----------------------------------------
ci/baselines/exposure_baseline.json holds the over-exposed declarations we
already know about, keyed `file::Type.name` (no line numbers; overloads share
a key). NEW = over-exposed tonight and not on the baseline; FIXED = on the
baseline and no longer over-exposed. A declaration that moved file with the
same `Type.name` is neither. The baseline only SHRINKS: `--shrink-baseline`
drops fixed keys and never adds; `--update-baseline` re-baselines deliberately
(say why in the commit). Same shrink guard as complexity: if more than half
of the baseline (and more than 20 keys) vanished at once, nothing shrinks.

Stdlib only (complexity_metrics' pure helpers); ~5 s on the whole tree.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import complexity_metrics as cm  # noqa: E402  (pure helpers; lizard is never imported)

COULD_BE_PRIVATE = "could-be-private"
WIDENED_FOR_SPLIT = "widened-for-split"
FINE = "fine"
OVER_EXPOSED = (COULD_BE_PRIVATE, WIDENED_FOR_SPLIT)

TOP_N = 20
SHORT_NAME = 4          # names shorter than this are "short"
COMMON_FILES = 50       # names in more files than this (per module) are "common"
SCHEMA_VERSION = 1

DEFAULT_BASELINE = os.path.join("ci", "baselines", "exposure_baseline.json")
TEST_ROOTS = ("VideoScan/VideoScanTests", "VideoScan/VideoScanCore/Tests")

SHRINK_GUARD_FRACTION = cm.SHRINK_GUARD_FRACTION
SHRINK_GUARD_MIN = cm.SHRINK_GUARD_MIN

# Witness names that are skipped wherever they appear.
ALWAYS_WITNESS = frozenset({
    "body", "id", "description", "debugDescription", "hash", "hashValue",
    "errorDescription", "failureReason", "recoverySuggestion", "helpAnchor",
    "previews", "defaultValue", "rawValue", "allCases", "transferRepresentation",
    "objectWillChange", "makeBody", "makeNSView", "updateNSView", "dismantleNSView",
    "makeNSViewController", "updateNSViewController", "makeCoordinator",
    "sizeThatFits", "placeSubviews", "animatableData", "main", "CodingKeys",
    "unownedExecutor", "customMirror", "playgroundDescription", "Coordinator",
})
# Witness names skipped only inside a scope that declares a conformance.
CONFORMANCE_WITNESS = frozenset({
    "encode", "reduce", "path", "makeIterator", "makeAsyncIterator", "next",
    "startIndex", "endIndex", "index", "format", "parseStrategy", "compare",
    "order", "update", "run", "validate", "makeCache", "updateCache",
    "explicitAlignment", "spacing", "layoutProperties", "copy", "isEqual",
    "contains", "count", "isEmpty", "localizedDescription", "keyPath",
    "accessibilityLabel", "scene", "commands", "content", "label",
})
_APPLE_PARAM = re.compile(r"^\s*(?:\w+\s+)?\w+\s*:\s*(?:inout\s+)?"
                          r"(?:NS|AV|UN|WK|PH|VN|SF|QL|MK|CL|CB|AS|SK|CA|CG|CK|MTL|UI)[A-Z]\w*")

_ACCESS = ("public", "open", "package", "private", "fileprivate", "internal")
_DECL = re.compile(
    r"^\s*(?P<attrs>(?:@[\w.]+(?:\([^)]*\))?\s+)*)"
    r"(?P<mods>(?:(?:public|private|fileprivate|internal|open|package)(?:\(set\))?\s+"
    r"|(?:static|class|final|override|mutating|nonmutating|lazy|weak|unowned(?:\(\w+\))?"
    r"|nonisolated(?:\(unsafe\))?|convenience|required|dynamic|indirect|optional|consuming"
    r"|borrowing|distributed|isolated|prefix|postfix|infix)\s+)*)"
    r"(?P<kind>func|var|let|init|subscript|struct|class|enum|actor|protocol|extension"
    r"|typealias|associatedtype|case)\b(?P<rest>.*)$")
_ATTR_ONLY = re.compile(r"^\s*(?:@[\w.]+(?:\([^)]*\))?\s*)+$")
_ATTR_NAME = re.compile(r"@([\w.]+)")
_NAME = re.compile(r"\s*`?([A-Za-z_][A-Za-z0-9_]*)`?")
_TYPE_NAME = re.compile(r"\s*([A-Za-z_][\w.]*)")
_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_STR_OR_COMMENT = re.compile(r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|//[^\n]*|/\*[\s\S]*?\*/')

TYPE_KINDS = ("struct", "class", "enum", "actor")
SCOPE_KINDS = TYPE_KINDS + ("protocol", "extension")
_OBJC_ATTRS = {"objc", "objcMembers", "IBAction", "IBOutlet", "IBInspectable", "NSManaged",
               "IBSegueAction", "main", "NSApplicationMain", "UIApplicationMain"}


# ---------------------------------------------------------------------------
# records

@dataclass
class Decl:
    file: str
    module: str
    kind: str           # func | var | let | init | subscript | struct | class | enum | actor
    name: str
    scope: Tuple[str, ...]      # enclosing type / extension names, outermost first
    line: int
    classification: str = FINE

    @property
    def qualified(self) -> str:
        return ".".join(self.scope + (self.name,))

    @property
    def key(self) -> str:
        return f"{self.file}::{self.qualified}"

    @property
    def outer_type(self) -> str:
        return self.scope[0].split(".", 1)[0] if self.scope else ""


@dataclass
class _Scope:
    kind: str                   # struct | class | enum | actor | protocol | extension | code
    name: str = ""
    restricted: bool = False    # members are private/fileprivate/public by default
    objc: bool = False
    conforms: bool = False


# ---------------------------------------------------------------------------
# source preparation (pure)

def strip_for_structure(src: str) -> str:
    """Code with every string literal replaced by `""` and every comment by
    spaces; newlines kept, so line numbers stay true. Regex and raw string
    literals go first (complexity_metrics' tokenizer), so their braces and
    quotes cannot unbalance anything."""
    src = cm.neutralize_swift_for_lizard(src)

    def repl(m: "re.Match[str]") -> str:
        text = m.group(0)
        if text.startswith('"'):
            return '""' + "\n" * text.count("\n")
        return " " + "\n" * text.count("\n")
    return _STR_OR_COMMENT.sub(repl, src)


def strip_comments(src: str) -> str:
    """Comments removed, string literals KEPT (an interpolation is a use)."""
    def repl(m: "re.Match[str]") -> str:
        text = m.group(0)
        return text if text.startswith('"') else " " + "\n" * text.count("\n")
    return _STR_OR_COMMENT.sub(repl, src)


def tokens(src: str) -> Set[str]:
    return set(_TOKEN.findall(strip_comments(src)))


def module_of(path: str) -> str:
    """Swift module a file compiles into (tests map to the module they test)."""
    if path.startswith("VideoScan/VideoScanCore/Sources/"):
        return "core:" + path.split("/")[3]
    if path.startswith("VideoScan/VideoScanCore/Tests/"):
        return "core-tests"
    if path.startswith("VideoScan/VideoScanTests/"):
        return "app-tests"
    if path.startswith("swift_cli/"):
        return "swift_cli"
    return "app"


def tests_see(module: str, test_module: str) -> bool:
    if test_module == "app-tests":
        return module == "app"
    if test_module == "core-tests":
        return module.startswith("core:")
    return False


# ---------------------------------------------------------------------------
# declaration parsing (pure)

def _access_of(mods: str) -> Optional[str]:
    for word in re.findall(r"(\w+)(\(set\))?", mods):
        if word[0] in _ACCESS and not word[1]:
            return word[0]
    return None


def _header_conforms(header: str) -> bool:
    """`struct Foo<T: P>: Bar where …` -> True (a conformance list)."""
    head = re.sub(r"<[^<>]*(?:<[^<>]*>[^<>]*)*>", "", header)
    head = head.split(" where ", 1)[0]
    return ":" in head


def parse_decls(path: str, src: str, protocol_reqs: Optional[Set[str]] = None
                ) -> Tuple[List[Decl], Set[str]]:
    """(counted declarations, protocol requirement names) for one file.

    `protocol_reqs` (names required by any protocol in the repo) are skipped
    as likely witnesses; pass None on the first pass, which only collects."""
    module = module_of(path)
    if src.startswith("#!"):
        return [], set()        # a one-file `swift X.swift` script: private buys nothing
    code = strip_for_structure(src)
    stack: List[_Scope] = []
    pending: Optional[_Scope] = None
    pending_header = ""
    attrs_above: Set[str] = set()
    decls: List[Decl] = []
    reqs: Set[str] = set()

    def member_level() -> bool:
        return not stack or stack[-1].kind != "code"

    for lineno, line in enumerate(code.split("\n"), 1):
        stripped = line.strip()
        if stripped and _ATTR_ONLY.match(line):
            attrs_above |= set(_ATTR_NAME.findall(line))
            continue
        m = _DECL.match(line) if member_level() and pending is None else None
        if m:
            attrs = attrs_above | set(_ATTR_NAME.findall(m.group("attrs")))
            mods, kind, rest = m.group("mods"), m.group("kind"), m.group("rest")
            access = _access_of(mods)
            scope = stack[-1] if stack else None
            if kind in SCOPE_KINDS:
                nm = _TYPE_NAME.match(rest)
                name = nm.group(1) if nm else "?"
                restricted = bool(scope and scope.restricted) or access in ("private", "fileprivate")
                if kind == "extension" and access in ("public", "open", "package"):
                    restricted = True
                pending = _Scope(kind=kind, name=name, restricted=restricted,
                                 objc=bool(scope and scope.objc) or bool(attrs & {"objc", "objcMembers"}))
                pending_header = rest
                nested_type = kind in TYPE_KINDS and scope is not None and scope.kind != "protocol"
                if nested_type and _counts(scope, access, mods, attrs, name, kind, rest, protocol_reqs):
                    decls.append(Decl(path, module, kind, name, _names(stack), lineno))
            elif scope is not None and scope.kind == "protocol":
                nm = _NAME.match(rest)
                if nm and kind in ("func", "var", "let", "subscript", "init", "associatedtype", "typealias"):
                    reqs.add(nm.group(1) if kind not in ("init", "subscript") else kind)
            elif kind in ("func", "var", "let", "init", "subscript"):
                if kind in ("init", "subscript"):
                    name = kind
                else:
                    nm = _NAME.match(rest)
                    name = nm.group(1) if nm else ""
                if name and _counts(scope, access, mods, attrs, name, kind, rest, protocol_reqs):
                    decls.append(Decl(path, module, kind, name, _names(stack), lineno))
        if stripped:
            attrs_above = set()
        if pending is not None and not m:
            pending_header += " " + stripped
        for ch in line:
            if ch == "{":
                if pending is not None:
                    pending.conforms = _header_conforms(pending_header.split("{", 1)[0])
                    stack.append(pending)
                    pending = None
                else:
                    stack.append(_Scope("code"))
            elif ch == "}":
                if stack:
                    stack.pop()
    return decls, reqs


def _names(stack: Sequence[_Scope]) -> Tuple[str, ...]:
    return tuple(s.name for s in stack if s.kind != "code")


def _counts(scope: Optional[_Scope], access: Optional[str], mods: str, attrs: Set[str],
            name: str, kind: str, rest: str, protocol_reqs: Optional[Set[str]]) -> bool:
    """Is this declaration internal and in scope for the metric?"""
    if access not in (None, "internal"):
        return False
    if access is None and scope is not None and scope.restricted:
        return False            # private/fileprivate type, private or public extension
    if re.search(r"\boverride\b", mods) or attrs & _OBJC_ATTRS:
        return False
    if scope is not None and scope.objc and kind in ("func", "var", "let", "init", "subscript"):
        return False
    if name in ALWAYS_WITNESS or name.startswith("_"):
        return False
    conforms = scope is not None and scope.conforms
    if conforms and name in CONFORMANCE_WITNESS:
        return False
    if protocol_reqs is not None and name in protocol_reqs:
        return False
    if kind == "func":
        params = rest.split("(", 1)[1] if "(" in rest else ""
        if _APPLE_PARAM.match(params):
            return False        # delegate / data-source method
    if kind == "init" and conforms and re.match(r"\s*\??\s*\(\s*(from|rawValue|coder)\b", rest):
        return False
    return True


# ---------------------------------------------------------------------------
# classification (pure)

def _extends(file: str, type_name: str, file_text: str) -> bool:
    """`file` is `T.swift` / `T+*.swift` and declares `extension T` (or T)."""
    base = os.path.basename(file)
    if not (base == f"{type_name}.swift" or base.startswith(f"{type_name}+")):
        return False
    return bool(re.search(rf"\b(?:extension|struct|class|enum|actor)\s+{re.escape(type_name)}\b", file_text))


def classify(decls: Sequence[Decl], file_tokens: Dict[str, Set[str]],
             file_texts: Dict[str, str]) -> None:
    """Fill `classification` on every declaration. `file_tokens` covers the
    measured files AND the test files (repo-relative path -> identifier set);
    `file_texts` the measured files (for the `extension T` check)."""
    by_module: Dict[str, List[str]] = {}
    for path in file_tokens:
        by_module.setdefault(module_of(path), []).append(path)
    index: Dict[str, Dict[str, Set[str]]] = {}      # module -> token -> files

    def module_index(module: str) -> Dict[str, Set[str]]:
        if module not in index:
            idx: Dict[str, Set[str]] = {}
            files = list(by_module.get(module, []))
            for test_module, paths in by_module.items():
                if tests_see(module, test_module):
                    files += paths
            for path in files:
                for tok in file_tokens[path]:
                    idx.setdefault(tok, set()).add(path)
            index[module] = idx
        return index[module]

    for d in decls:
        if d.kind == "subscript":
            d.classification = FINE
            continue
        idx = module_index(d.module)
        # An init is used through its type's name (`Foo(`, `Foo.init`).
        lookup = d.scope[-1].rsplit(".", 1)[-1] if d.kind == "init" and d.scope else d.name
        files = idx.get(lookup, set()) | {d.file}
        others = files - {d.file}
        if not others:
            d.classification = COULD_BE_PRIVATE
            continue
        t = d.outer_type
        common = len(d.name) < SHORT_NAME or len(files) > COMMON_FILES
        if t and not common and d.kind != "init" and all(
                p in file_texts and _extends(p, t, file_texts[p]) for p in others):
            d.classification = WIDENED_FOR_SPLIT
        else:
            d.classification = FINE


def dedupe(decls: Iterable[Decl]) -> List[Decl]:
    """One entry per key (overloads collapse); over-exposed wins."""
    out: Dict[str, Decl] = {}
    for d in decls:
        cur = out.get(d.key)
        if cur is None or (cur.classification == FINE and d.classification != FINE):
            out[d.key] = d
    return sorted(out.values(), key=lambda d: (d.file, d.line, d.name))


# ---------------------------------------------------------------------------
# scanning

def list_test_files(root: str) -> List[str]:
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *TEST_ROOTS],
                             capture_output=True, check=True)
        paths = [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        paths = []
        for top in TEST_ROOTS:
            for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
                dirnames[:] = [d for d in dirnames if d not in cm.SKIP_DIRS]
                paths += [os.path.relpath(os.path.join(dirpath, n), root).replace(os.sep, "/")
                          for n in filenames]
    return sorted(p for p in paths if p.endswith(".swift")
                  and not any(seg in cm.SKIP_DIRS for seg in p.split("/")[:-1]))


def _read(root: str, rel: str) -> Optional[str]:
    try:
        with open(os.path.join(root, rel), "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def analyze(sources: Dict[str, str], test_sources: Dict[str, str]) -> List[Decl]:
    """Parse, classify and dedupe. `sources` are the measured files."""
    reqs: Set[str] = set()
    for path, text in sources.items():
        reqs |= parse_decls(path, text)[1]
    decls: List[Decl] = []
    for path, text in sources.items():
        decls += parse_decls(path, text, reqs)[0]
    file_tokens = {p: tokens(t) for p, t in list(sources.items()) + list(test_sources.items())}
    classify(decls, file_tokens, sources)
    return dedupe(decls)


def scan(root: str) -> Tuple[List[Decl], Dict[str, int]]:
    sources = {rel: t for rel in cm.list_files(root) if rel.endswith(".swift")
               for t in [_read(root, rel)] if t is not None}
    tests = {rel: t for rel in list_test_files(root) for t in [_read(root, rel)] if t is not None}
    return analyze(sources, tests), {rel: t.count("\n") for rel, t in sources.items()}


# ---------------------------------------------------------------------------
# aggregation

def _bucket() -> dict:
    return {"files": 0, "decls": 0, "could_be_private": 0, "widened_for_split": 0, "fine": 0}


_FIELD = {COULD_BE_PRIVATE: "could_be_private", WIDENED_FOR_SPLIT: "widened_for_split", FINE: "fine"}


def aggregate(decls: Sequence[Decl], file_lines: Dict[str, int]) -> dict:
    totals, folders = _bucket(), {}
    for path in file_lines:
        for b in (totals, folders.setdefault(cm.folder_of(path), _bucket())):
            b["files"] += 1
    for d in decls:
        for b in (totals, folders.setdefault(cm.folder_of(d.file), _bucket())):
            b["decls"] += 1
            b[_FIELD[d.classification]] += 1
    return {"totals": totals, "by_folder": dict(sorted(folders.items()))}


def per_file(decls: Sequence[Decl], file_lines: Dict[str, int]) -> Dict[str, dict]:
    out = {p: {"lines": n, "decls": 0, "could_be_private": [], "widened_for_split": []}
           for p, n in sorted(file_lines.items())}
    for d in decls:
        rec = out.setdefault(d.file, {"lines": 0, "decls": 0, "could_be_private": [], "widened_for_split": []})
        rec["decls"] += 1
        if d.classification != FINE:
            rec[_FIELD[d.classification]].append(d.qualified)
    return out


def top_files(files: Dict[str, dict], limit: int = TOP_N) -> List[dict]:
    ranked = sorted(((p, r) for p, r in files.items() if r["could_be_private"]),
                    key=lambda pr: (-len(pr[1]["could_be_private"]), -len(pr[1]["widened_for_split"]), pr[0]))
    return [{"file": p, "could_be_private": len(r["could_be_private"]),
             "widened_for_split": len(r["widened_for_split"]), "decls": r["decls"]}
            for p, r in ranked[:limit]]


# ---------------------------------------------------------------------------
# ratchet

def over_exposed(decls: Sequence[Decl]) -> Dict[str, Decl]:
    return {d.key: d for d in decls if d.classification in OVER_EXPOSED}


def load_baseline(path: str) -> Dict[str, str]:
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        return {str(k): str(v) for k, v in json.load(handle).get("entries", {}).items()}


def write_baseline(path: str, entries: Dict[str, str]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    payload = {
        "note": ("Over-exposure baseline (scripts/exposure_metrics.py): internal declarations "
                 "referenced only in their own file (could-be-private) or only from T+*.swift "
                 "extensions of their type (widened-for-split), keyed file::Type.name. The "
                 "nightly REPORTS over-exposed declarations not on this list as NEW; there is "
                 "no commit gate. It only shrinks (`--shrink-baseline`); regrow it deliberately "
                 "with `--update-baseline` and say why in the commit."),
        "entry_count": len(entries),
        "entries": dict(sorted(entries.items())),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=1)
        handle.write("\n")


def _qual(key: str) -> str:
    return key.split("::", 1)[-1]


def ratchet(decls: Sequence[Decl], baseline: Dict[str, str]) -> dict:
    """{"new", "fixed", "moved", "next_baseline", "shrink_skipped"}. Pure.
    `next_baseline` only ever drops keys (a moved declaration keeps its OLD
    key, so nothing is added)."""
    current = over_exposed(decls)
    unknown = [d for k, d in current.items() if k not in baseline]
    vanished = {k for k in baseline if k not in current}
    pool: Dict[str, List[str]] = {}
    for k in sorted(vanished):
        pool.setdefault(_qual(k), []).append(k)
    moved: Dict[str, str] = {}
    for d in sorted(unknown, key=lambda d: d.key):
        old = pool.get(d.qualified)
        if old:
            moved[d.key] = old.pop(0)
    new = [d for d in unknown if d.key not in moved]
    fixed = sorted(vanished - set(moved.values()))
    nxt = {k: v for k, v in baseline.items() if k not in fixed}
    shrink_skipped = None
    if not decls:
        shrink_skipped = "no declarations measured: the scan found nothing"
    elif len(fixed) > SHRINK_GUARD_MIN and len(fixed) > SHRINK_GUARD_FRACTION * len(baseline):
        shrink_skipped = (f"{len(fixed)} of {len(baseline)} baseline entries vanished in one run: "
                          "more likely a broken scan than a refactor")
    if shrink_skipped:
        nxt = dict(baseline)
    return {"new": sorted(new, key=lambda d: d.key), "fixed": fixed, "moved": moved,
            "next_baseline": nxt, "shrink_skipped": shrink_skipped}


# ---------------------------------------------------------------------------
# reports

def build_row(decls: Sequence[Decl], file_lines: Dict[str, int], result: dict,
              baseline: Dict[str, str], ts: str, sha: str) -> dict:
    files = per_file(decls, file_lines)
    return {
        "schemaVersion": SCHEMA_VERSION, "ts": ts, "sha": sha, "run_kind": "nightly",
        **aggregate(decls, file_lines),
        "top20": top_files(files),
        "baseline_before": len(baseline),
        "baseline_after": len(result["next_baseline"]),
        "new": len(result["new"]),
        "fixed": len(result["fixed"]),
        "shrink_skipped": bool(result["shrink_skipped"]),
    }


def new_report(result: dict, baseline: Dict[str, str], ts: str, sha: str) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION, "ts": ts, "sha": sha,
        "new": [{"key": d.key, "file": d.file, "name": d.qualified, "kind": d.kind,
                 "classification": d.classification} for d in result["new"]],
        "fixed": len(result["fixed"]),
        "baseline_before": len(baseline),
        "baseline_after": len(result["next_baseline"]),
        "shrink_skipped": bool(result["shrink_skipped"]),
    }


def files_report(decls: Sequence[Decl], file_lines: Dict[str, int], ts: str, sha: str) -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "ts": ts, "sha": sha, "files": per_file(decls, file_lines)}


def alert_lines(report: dict, limit: int = 10) -> List[str]:
    """Morning digest: 🔴 for every NEW over-exposed declaration; quiet otherwise."""
    new = report.get("new") or []
    lines: List[str] = []
    if new:
        lines.append(f"🔴 Over-exposure ({str(report.get('ts', ''))[:10]}): {len(new)} NEW internal "
                     "declaration(s) that could be private or were widened for a file split — "
                     "make it private, or accept it with `scripts/exposure_metrics.py "
                     "--update-baseline` and say why in the commit")
        for d in new[:limit]:
            lines.append(f"   {d.get('classification', ''):<17} {os.path.basename(str(d.get('file', '')))} :: "
                         f"{d.get('name', '')}")
        if len(new) > limit:
            lines.append(f"   … and {len(new) - limit} more in metrics/exposure_new_latest.json")
    if report.get("fixed"):
        lines.append(f"✅ Over-exposure: {report['fixed']} baseline declaration(s) fixed — "
                     "`python3 scripts/exposure_metrics.py --shrink-baseline` to commit the shrink.")
    if report.get("shrink_skipped"):
        lines.append("⚠️  Over-exposure baseline not shrunk: most of it vanished at once (broken scan?)")
    return lines


def markdown_report(row: dict) -> str:
    t = row["totals"]
    lines = ["## Over-exposure (report only)", "",
             f"{t['decls']} internal declarations in {t['files']} files: **{t['could_be_private']} could be "
             f"private**, **{t['widened_for_split']} widened for a file split**, {t['fine']} fine.",
             f"Ratchet: **{row['new']} new**, {row['fixed']} fixed; baseline {row['baseline_before']} → "
             f"{row['baseline_after']}.", "",
             "| # | Could be private | Widened | Decls | File |", "|---:|---:|---:|---:|---|"]
    for i, f in enumerate(row["top20"], 1):
        lines.append(f"| {i} | {f['could_be_private']} | {f['widened_for_split']} | {f['decls']} | `{f['file']}` |")
    return "\n".join(lines) + "\n"


def _write_json(path: str, payload, line: bool = False) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        if line:
            handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
        else:
            json.dump(payload, handle, indent=1)
            handle.write("\n")


def _set_output(name: str, value) -> None:
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--row-out", default="", help="metrics row (one JSON line); default stdout")
    parser.add_argument("--files-out", default="", help="per-file map JSON")
    parser.add_argument("--new-out", default="", help="NEW over-exposed declarations JSON")
    parser.add_argument("--update-baseline", action="store_true",
                        help="rewrite --baseline from today's over-exposed declarations (deliberate)")
    parser.add_argument("--shrink-baseline", action="store_true",
                        help="drop fixed entries from --baseline; never adds")
    parser.add_argument("--alert", metavar="NEW_JSON",
                        help="print morning-digest lines for a --new-out report ('-' = stdin) and exit")
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    args = parser.parse_args(argv)

    if args.alert:
        try:
            text = sys.stdin.read() if args.alert == "-" else open(args.alert, encoding="utf-8").read()
            for line in alert_lines(json.loads(text)):
                print(line)
        except (OSError, ValueError):
            pass
        return 0

    sha = (args.sha or "")[:8]
    if not sha:
        try:
            sha = subprocess.run(["git", "-C", args.root, "rev-parse", "--short=8", "HEAD"],
                                 capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            sha = "unknown"
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    decls, file_lines = scan(args.root)
    baseline_path = os.path.join(args.root, args.baseline) if not os.path.isabs(args.baseline) else args.baseline

    if args.update_baseline:
        entries = {k: d.classification for k, d in over_exposed(decls).items()}
        write_baseline(baseline_path, entries)
        print(f"Baseline written: {args.baseline} ({len(entries)} over-exposed declarations)")
        return 0

    baseline = load_baseline(baseline_path)
    result = ratchet(decls, baseline)
    if args.shrink_baseline:
        if result["shrink_skipped"]:
            print(f"Not shrinking: {result['shrink_skipped']}")
            return 1
        nxt = result["next_baseline"]
        if set(nxt) - set(baseline):
            print("🔴 Refusing to shrink: the result would add entries")
            return 1
        write_baseline(baseline_path, nxt)
        print(f"Baseline shrunk: {len(baseline)} -> {len(nxt)} ({len(result['fixed'])} fixed); nothing added.")
        return 0

    row = build_row(decls, file_lines, result, baseline, ts, sha)
    if args.row_out:
        _write_json(args.row_out, row, line=True)
    else:
        print(json.dumps(row, separators=(",", ":")))
    if args.files_out:
        _write_json(args.files_out, files_report(decls, file_lines, ts, sha))
    if args.new_out:
        _write_json(args.new_out, new_report(result, baseline, ts, sha))
    report = markdown_report(row)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    print(report, file=sys.stderr)
    _set_output("exposure_new", row["new"])
    _set_output("exposure_could_be_private", row["totals"]["could_be_private"])
    _set_output("exposure_widened", row["totals"]["widened_for_split"])
    return 0            # report only


if __name__ == "__main__":
    raise SystemExit(main())
