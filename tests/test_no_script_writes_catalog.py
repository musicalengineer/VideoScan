"""SENSOR (2026-10-19, cutover acceptance audit gap 3): no script writes the
catalog behind the app's back.

The catalog has lived in catalog.sqlite since the 10/18 cutover, and
catalog.json is frozen. Before this sensor, a dozen Python repair / merge
tools still rewrote catalog.json with os.replace — after the cutover their
output went nowhere, and before it they raced the app. Rick: "jettison json
as fast as we can while still being responsible". So:

  1. no script under scripts/ or tools/ names catalog.json in code AND
     writes files (os.replace, open(..., "w"), write_text, json.dump to a
     file, ...), except the allowlisted exporters below, each with its reason;
  2. no shell script there names catalog.json or catalog.sqlite;
  3. only scripts/catalog_db.py names catalog.sqlite, and it opens the file
     with a `?mode=ro` URI plus `PRAGMA query_only` — and the engine really
     refuses a write through it (run against a synthetic catalog.sqlite built
     from the real DDL);
  4. catalog_db refuses a catalog with no catalog.cutover, and a
     catalog.json path, instead of falling back to the JSON.
"""
from __future__ import annotations

import ast
import sqlite3
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import catalog_db  # noqa: E402
from catalog_sqlite_fixture import Catalog  # noqa: E402

SCAN_ROOTS = [ROOT / "scripts", ROOT / "tools"]
SKIP_PARTS = {"venv", ".venv", ".build", "node_modules", "__pycache__", ".derivedData"}

# path (relative to the repo) -> why it may name catalog.json AND write files.
ALLOWED_JSON_WRITERS = {
    "scripts/hallie_demo/snapshot.py":
        "writes its OWN export file named catalog.json into --out (a scratch snapshot dir); "
        "it reads the app's catalog through catalog_db (read-only)",
}

WRITE_CALLS = {("os", "replace"), ("os", "rename"), ("shutil", "move"), ("shutil", "copy"),
               ("shutil", "copy2"), ("shutil", "copyfile")}
WRITE_METHODS = {"write_text", "write_bytes"}


def _files(suffixes: tuple[str, ...]) -> list[Path]:
    out = []
    for root in SCAN_ROOTS:
        for p in root.rglob("*"):
            if p.is_file() and p.suffix in suffixes and not (SKIP_PARTS & set(p.relative_to(ROOT).parts)):
                out.append(p)
    return sorted(out)


def _docstring_nodes(tree: ast.AST) -> set[int]:
    ids = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, "body", [])
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                ids.add(id(body[0].value))
    return ids


def _code_strings(tree: ast.AST) -> list[str]:
    """String constants in code (docstrings excluded; f-string pieces included)."""
    skip = _docstring_nodes(tree)
    return [n.value for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in skip]


def _is_std_stream(node: ast.AST) -> bool:
    return (isinstance(node, ast.Attribute) and node.attr in {"stdout", "stderr"}
            and isinstance(node.value, ast.Name) and node.value.id == "sys")


def _write_sites(tree: ast.AST) -> list[str]:
    sites = []
    for n in ast.walk(tree):
        if not isinstance(n, ast.Call):
            continue
        f = n.func
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and (f.value.id, f.attr) in WRITE_CALLS:
            sites.append(f"{f.value.id}.{f.attr} (line {n.lineno})")
        elif isinstance(f, ast.Attribute) and f.attr in WRITE_METHODS:
            sites.append(f".{f.attr} (line {n.lineno})")
        elif isinstance(f, ast.Attribute) and f.attr == "dump" and isinstance(f.value, ast.Name) \
                and f.value.id == "json" and len(n.args) >= 2 and not _is_std_stream(n.args[1]):
            sites.append(f"json.dump (line {n.lineno})")
        elif (isinstance(f, ast.Name) and f.id == "open") or (isinstance(f, ast.Attribute) and f.attr in {"open", "fdopen"}):
            # open(path, mode) / os.fdopen(fd, mode) / Path.open(mode): the mode is
            # the second positional, or the first for a Path method, or mode=.
            candidates = list(n.args[:2]) + [k.value for k in n.keywords if k.arg == "mode"]
            for mode in candidates:
                if isinstance(mode, ast.Constant) and isinstance(mode.value, str) and len(mode.value) <= 3 \
                        and set(mode.value) <= set("rwabxt+") and set(mode.value) & set("wax+"):
                    sites.append(f"open(mode={mode.value!r}) (line {n.lineno})")
                    break
    return sites


def _parse(p: Path) -> ast.AST:
    return ast.parse(p.read_text(encoding="utf-8"), filename=str(p))


PY_FILES = _files((".py",))


def test_scan_sees_the_scripts():
    """The sensor is not vacuous: it parses the real script tree."""
    rel = {p.relative_to(ROOT).as_posix() for p in PY_FILES}
    assert "scripts/catalog_db.py" in rel and "scripts/events_prototype.py" in rel
    assert len(rel) > 50


def test_no_script_writes_catalog_json():
    offenders = []
    for p in PY_FILES:
        rel = p.relative_to(ROOT).as_posix()
        tree = _parse(p)
        if not any("catalog.json" in s for s in _code_strings(tree)):
            continue
        sites = _write_sites(tree)
        if sites and rel not in ALLOWED_JSON_WRITERS:
            offenders.append(f"{rel}: names catalog.json and writes files: {', '.join(sites)}")
    assert not offenders, ("catalog.json is frozen since the SQLite cutover; scripts read catalog.sqlite "
                           "through scripts/catalog_db.py and never write the catalog:\n" + "\n".join(offenders))


def test_allowlist_has_no_stale_entries():
    for rel in ALLOWED_JSON_WRITERS:
        assert (ROOT / rel).exists(), f"allowlisted {rel} no longer exists — drop the entry"


def test_no_shell_script_touches_the_catalog_files():
    offenders = [p.relative_to(ROOT).as_posix() for p in _files((".sh", ".zsh", ".bash"))
                 if "catalog.json" in p.read_text(encoding="utf-8", errors="replace")
                 or "catalog.sqlite" in p.read_text(encoding="utf-8", errors="replace")]
    assert not offenders, offenders


def test_only_catalog_db_names_catalog_sqlite():
    offenders = []
    for p in PY_FILES:
        rel = p.relative_to(ROOT).as_posix()
        if rel == "scripts/catalog_db.py":
            continue
        if any("catalog.sqlite" in s for s in _code_strings(_parse(p))):
            offenders.append(rel)
    assert not offenders, f"open catalog.sqlite only through scripts/catalog_db.connect(): {offenders}"


def test_catalog_db_opens_read_only_by_construction():
    tree = _parse(ROOT / "scripts" / "catalog_db.py")
    connects = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                and n.func.attr == "connect" and isinstance(n.func.value, ast.Name) and n.func.value.id == "sqlite3"]
    assert connects, "catalog_db must open the database itself"
    for call in connects:
        uri = next((k.value for k in call.keywords if k.arg == "uri"), None)
        assert isinstance(uri, ast.Constant) and uri.value is True, f"sqlite3.connect at line {call.lineno} without uri=True"
    strings = _code_strings(tree)
    assert any(s == "?mode=ro" for s in strings)
    assert any("PRAGMA query_only = ON" in s for s in strings)
    assert not _write_sites(tree), _write_sites(tree)


def test_engine_refuses_a_write_through_catalog_db(tmp_path):
    db = Catalog(tmp_path)
    db.add("/Volumes/LaCie/a.mov")
    path = db.close()
    before = path.read_bytes()
    conn = catalog_db.connect(path)
    try:
        with pytest.raises(sqlite3.OperationalError):
            conn.execute("UPDATE files SET filename = 'x'")
        with pytest.raises(sqlite3.OperationalError):
            conn.execute("CREATE TABLE intruder (x)")
    finally:
        conn.close()
    assert path.read_bytes() == before


def test_refuses_without_cutover_latch_and_never_reads_json(tmp_path):
    db = Catalog(tmp_path, latch=False)
    db.add("/Volumes/LaCie/a.mov")
    path = db.close()
    (tmp_path / "catalog.json").write_text('{"records":[{"id":"x","fullPath":"/stale"}]}')
    with pytest.raises(catalog_db.CatalogUnavailable, match="catalog.cutover"):
        catalog_db.load(path)
    with pytest.raises(catalog_db.CatalogUnavailable, match="frozen"):
        catalog_db.load(tmp_path / "catalog.json")
