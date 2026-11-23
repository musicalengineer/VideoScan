"""scripts/sealed_home.py — the test hosts' home: a COPY of the real App Support, never the real one
(DECISIONS 2026-11-22: tests never open the real catalog; they use a synthetic catalog or an injected copy)."""
from __future__ import annotations

import importlib.util
import os
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sealed_home", ROOT / "scripts" / "sealed_home.py")
sh = importlib.util.module_from_spec(spec)
sys.modules["sealed_home"] = sh
spec.loader.exec_module(sh)


def live_db(path: Path, rows: int) -> sqlite3.Connection:
    """A WAL-mode database with `rows` committed rows still in its -wal (as the running app leaves it)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(str(path))
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("CREATE TABLE r(id INTEGER PRIMARY KEY, v TEXT)")
    c.executemany("INSERT INTO r(v) VALUES (?)", [(f"row{i}",) for i in range(rows)])
    c.commit()
    return c                                    # held open: the WAL is not checkpointed


def snapshot(root: Path) -> dict:
    return {str(p.relative_to(root)): (p.stat().st_size, p.stat().st_mtime_ns, p.read_bytes())
            for p in sorted(root.rglob("*")) if p.is_file()}


def test_the_sealed_home_holds_a_copy_of_app_support_and_the_real_one_is_never_written(tmp_path):
    real = tmp_path / "real" / "Library" / "Application Support" / "VideoScan"
    keep = live_db(real / "catalog.sqlite", 50)
    (real / "catalog.cutover").write_text("")          # the latch the catalog door requires (catalog_db.preflight)
    live_db(real / "viewer-catalog" / "catalog.sqlite", 7).close()
    (real / "family-tree" / "compiled").mkdir(parents=True)
    (real / "family-tree" / "compiled" / "tree.json").write_text('{"people": 3}')
    assert (real / "catalog.sqlite-wal").exists(), "fixture: the live catalog has a WAL"
    before = snapshot(tmp_path / "real")

    home = sh.prepare(tmp_path / "run" / "home", real_home=tmp_path / "real")
    copy = home / "Library" / "Application Support" / "VideoScan"
    assert not (copy / "catalog.sqlite-wal").exists(), "a cloned -wal beside a backed-up database"
    # the copy: every committed row (WAL included), the other files, the standard folders
    with sqlite3.connect(str(copy / "catalog.sqlite")) as c:
        assert c.execute("SELECT count(*) FROM r").fetchone()[0] == 50
        assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    with sqlite3.connect(str(copy / "viewer-catalog" / "catalog.sqlite")) as c:
        assert c.execute("SELECT count(*) FROM r").fetchone()[0] == 7
    assert (copy / "family-tree" / "compiled" / "tree.json").read_text() == '{"people": 3}'
    for sub in ("Logs", "Preferences", "Caches"):
        assert (home / "Library" / sub).is_dir()
    # writing through the copy never reaches the real files
    with sqlite3.connect(str(copy / "catalog.sqlite")) as c:
        c.execute("DELETE FROM r")
    (copy / "family-tree" / "compiled" / "tree.json").write_text("changed")
    keep.close()
    after = snapshot(tmp_path / "real")
    for name in ("family-tree/compiled/tree.json",):
        assert before["Library/Application Support/VideoScan/" + name] == after["Library/Application Support/VideoScan/" + name]
    with sqlite3.connect(f"file:{real / 'catalog.sqlite'}?mode=ro", uri=True) as c:
        assert c.execute("SELECT count(*) FROM r").fetchone()[0] == 50, "the real catalog lost rows"


def test_no_real_app_support_gives_an_empty_sealed_home(tmp_path):
    home = sh.prepare(tmp_path / "home", real_home=tmp_path / "nobody")
    assert (home / "Library" / "Application Support").is_dir()
    assert not (home / "Library" / "Application Support" / "VideoScan").exists()


def test_the_sealed_home_is_refused_inside_the_real_home_library(tmp_path):
    real = tmp_path / "real"
    (real / "Library" / "Application Support" / "VideoScan").mkdir(parents=True)
    for bad in (real / "Library" / "Application Support" / "x", real):
        try:
            sh.prepare(bad, real_home=real)
        except sh.Refused:
            continue
        raise AssertionError(f"a sealed home at {bad} was accepted")


def test_a_sealed_home_under_the_real_caches_is_allowed(tmp_path):
    # RED 2026-11-22 (the first full run with the copy): run_tests keeps its runs in ~/Library/Caches;
    # "anywhere inside ~/Library" was refused, the app phase started no host and ran zero tests.
    real = tmp_path / "real"
    (real / "Library" / "Application Support" / "VideoScan").mkdir(parents=True)
    home = sh.prepare(real / "Library" / "Caches" / "videoscan-runall" / "runs" / "r1" / "home", real_home=real)
    assert (home / "Library" / "Application Support").is_dir()
    for bad in (real / "Library" / "Logs" / "x", real / "Library" / "Preferences" / "x"):
        try:
            sh.prepare(bad, real_home=real)
        except sh.Refused:
            continue
        raise AssertionError(f"a sealed home at {bad} was accepted")
