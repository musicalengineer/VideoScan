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


def test_the_copied_catalog_opens_read_only_as_the_production_shape_tests_open_it(tmp_path):
    # RED 2026-11-22 (full run with the copy, c6bbe6765): 13 production-shape tests take a .backup of
    # "the live catalog" through a READ-ONLY open; a WAL-mode copy with no -shm cannot be opened read-only
    # ("unable to open database file", sqlite3_backup_step 14). The copy is left in rollback-journal mode.
    real = tmp_path / "real" / "Library" / "Application Support" / "VideoScan"
    keep = live_db(real / "catalog.sqlite", 9)
    (real / "catalog.cutover").write_text("")
    home = sh.prepare(tmp_path / "run" / "home", real_home=tmp_path / "real")
    keep.close()
    copy = home / "Library" / "Application Support" / "VideoScan" / "catalog.sqlite"
    assert list(copy.read_bytes()[18:20]) == [1, 1], "the copy is left in WAL mode (header bytes 18-19)"
    import subprocess
    p = subprocess.run(["/usr/bin/sqlite3", f"file:{copy}?mode=ro", f".backup '{tmp_path / 'cli.sqlite'}'"],
                       capture_output=True, text=True)
    assert p.returncode == 0, f"the system sqlite3 cannot back up the copy read-only: {p.stderr.strip()}"
    ro = sqlite3.connect(f"file:{copy}?mode=ro", uri=True)
    try:
        assert ro.execute("SELECT count(*) FROM r").fetchone()[0] == 9
        out = sqlite3.connect(str(tmp_path / "b.sqlite"))
        ro.backup(out)                                   # what the tests' sqlite3 .backup does
        assert out.execute("SELECT count(*) FROM r").fetchone()[0] == 9
        out.close()
    finally:
        ro.close()


def test_the_model_cache_is_cloned_into_the_sealed_home(tmp_path):
    # 2026-11-22 (full sealed run 8ad9b0c7e: GREEN, but 2 SigLIP tests skipped — their weights live in
    # ~/.cache/huggingface, outside App Support). Public model files: cloned, never written back.
    real = tmp_path / "real"
    w = real / ".cache" / "huggingface" / "hub" / "models--google--siglip2" / "model.safetensors"
    w.parent.mkdir(parents=True)
    w.write_bytes(b"weights")
    home = sh.prepare(tmp_path / "home", real_home=real)
    copy = home / ".cache" / "huggingface" / "hub" / "models--google--siglip2" / "model.safetensors"
    assert copy.read_bytes() == b"weights"
    copy.write_bytes(b"changed")
    assert w.read_bytes() == b"weights", "a write to the clone reached the real model cache"


def test_the_sealed_home_has_its_own_tmp_and_leftovers_are_reported_by_prefix(tmp_path):
    # 2026-11-23: test hosts used the system temp dir; tests that never removed their folders left
    # ~18 GB there (MediaRepairEngineTests, SigVerify-…, CouplePortraitTests-…). The sealed home has its own
    # tmp (removed with it), and what a run leaves there is REPORTED by prefix — a leak is a bug.
    home = sh.prepare(tmp_path / "home", real_home=tmp_path / "nobody")
    tmp = home / "tmp"
    assert tmp.is_dir()
    for name in ("SigVerify-8F0C2E4B-1111-2222-3333-444455556666", "SigVerify-0A0B0C0D-1111-2222-3333-444455556666",
                 "test_media_repair_repeated_9D9D9D9D-1111-2222-3333-444455556666", "VideoScanTestLogs-31337"):
        (tmp / name).mkdir()
    (tmp / "SigVerify-8F0C2E4B-1111-2222-3333-444455556666" / "duplicate.mov").write_bytes(b"x" * 2048)
    report = sh.leftovers(tmp)
    assert [(r.prefix, r.count) for r in report][:1] == [("SigVerify-<id>", 2)], report
    assert {r.prefix for r in report} == {"SigVerify-<id>", "test_media_repair_repeated_<id>", "VideoScanTestLogs-<id>"}
    assert report[0].bytes >= 2048
    assert sh.leftovers(tmp_path / "absent") == []


def test_the_sealed_tmp_carries_the_runners_marker_and_the_report_ignores_it(tmp_path):
    # Codex 2026-11-23 #352 P1-1: TestHostScratch trusts VIDEOSCAN_TEST_TMP as a removal root only when it carries
    # the runner's marker (.videoscan-test-tmp) — the sealed tmp must carry it, and it is not a leftover.
    home = sh.prepare(tmp_path / "home", real_home=tmp_path / "nobody")
    assert (home / "tmp" / ".videoscan-test-tmp").is_file()
    assert sh.leftovers(home / "tmp") == [], "the marker is reported as a test's leftover"


def test_the_marker_never_follows_a_symlink_and_a_symlinked_tmp_is_refused(tmp_path):
    # Codex 2026-11-23 (runner deletion review) P1: write_text on an existing symlinked marker truncated its target.
    outside = tmp_path / "outside.txt"
    outside.write_text("precious")
    home = tmp_path / "home"
    (home / "tmp").mkdir(parents=True)
    (home / "tmp" / ".videoscan-test-tmp").symlink_to(outside)
    try:
        sh.prepare(home, real_home=tmp_path / "nobody")
        refused = False
    except sh.Refused:
        refused = True
    assert outside.read_text() == "precious", "the marker write followed a symlink and truncated its target"
    assert refused
    home2 = tmp_path / "home2"
    home2.mkdir()
    (tmp_path / "elsewhere").mkdir()
    (home2 / "tmp").symlink_to(tmp_path / "elsewhere")
    try:
        sh.prepare(home2, real_home=tmp_path / "nobody")
        raise AssertionError("a symlinked tmp was accepted")
    except sh.Refused:
        pass
    assert not (tmp_path / "elsewhere" / ".videoscan-test-tmp").exists()


def test_a_prepared_home_carries_its_owner_proof(tmp_path):
    home = sh.prepare(tmp_path / "home", real_home=tmp_path / "nobody")
    owner = home / ".videoscan-sealed-home"
    assert owner.is_file() and not owner.is_symlink()
    assert owner.read_text().split()[0] == str(os.getpid())


def test_a_home_that_is_itself_a_symlink_is_refused_and_nothing_is_written_through_it(tmp_path):
    # Codex 2026-11-23 (runner deletion review, round 2) P1: only components BENEATH home were checked.
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "sentinel.txt").write_text("keep")
    (tmp_path / "run").mkdir()
    (tmp_path / "run" / "home").symlink_to(outside)
    try:
        sh.prepare(tmp_path / "run" / "home", real_home=tmp_path / "nobody")
        raise AssertionError("a symlinked home was accepted")
    except sh.Refused:
        pass
    assert sorted(p.name for p in outside.iterdir()) == ["sentinel.txt"], "something was written through the link"


# ---- `run`: allocate a sealed home, run one command in it, free it (2026-11-23: every lane sealed) ----

import json as _json
import signal as _signal
import subprocess as _subprocess
import time as _time

SCRIPT = ROOT / "scripts" / "sealed_home.py"
# The child: records what it was given and whether the home it was pointed at exists and is a sealed home.
PROBE = r'''
import json, os, sys
keys = ("HOME", "CFFIXED_USER_HOME", "TMPDIR", "VIDEOSCAN_TEST_TMP")
env = {k: os.environ.get(k) for k in keys} | {"TEST_RUNNER_" + k: os.environ.get("TEST_RUNNER_" + k) for k in keys}
home = env["TEST_RUNNER_HOME"] or env["HOME"]
env["owner"] = os.path.isfile(os.path.join(home, ".videoscan-sealed-home"))
env["logs"] = os.path.isdir(os.path.join(home, "Library", "Logs"))
env["app"] = os.path.isdir(os.path.join(home, "Library", "Application Support", "VideoScan"))
json.dump(env, open(sys.argv[1], "w"))
sys.exit(int(sys.argv[2]))
'''


def _run(tmp_path, opts, rc=0, source=None):
    out = tmp_path / "probe.json"
    env = dict(os.environ, HOME="/Users/the-real-home", TMPDIR=str(tmp_path / "t") + "/")
    (tmp_path / "t").mkdir(exist_ok=True)
    if source:
        env["VIDEOSCAN_SEAL_SOURCE_HOME"] = str(source)
    p = _subprocess.run([sys.executable, str(SCRIPT), "run", *opts, "--", sys.executable, "-c", PROBE, str(out), str(rc)],
                        env=env, capture_output=True, text=True, timeout=60)
    return p, _json.loads(out.read_text())


def test_run_hands_the_test_runner_a_sealed_home_keeps_its_own_home_and_frees_it(tmp_path):
    p, got = _run(tmp_path, ["--empty"], rc=3)
    assert p.returncode == 3, p.stderr                       # the command's code, unchanged
    home = got["TEST_RUNNER_HOME"]
    assert home and home != "/Users/the-real-home" and got["owner"] and got["logs"], got
    assert got["TEST_RUNNER_CFFIXED_USER_HOME"] == home
    assert got["TEST_RUNNER_TMPDIR"] == got["TEST_RUNNER_VIDEOSCAN_TEST_TMP"] == home + "/tmp/"
    assert got["HOME"] == "/Users/the-real-home", "xcodebuild itself must keep the real home (its caches)"
    assert not got["app"], "--empty copies nothing"
    assert not Path(home).exists(), "the sealed home was not freed"
    # allocated in the per-user temp dir, NOT $TMPDIR (here a stand-in for a run's --out folder): the app's icon
    # guard trusts a test temp root only there, in /private/tmp or ~/Library/Caches (M4 2026-11-24)
    assert Path(home).parent == Path(os.confstr(65537)).resolve(), home
    assert not home.startswith(str(tmp_path / "t")), "allocated under $TMPDIR"


def test_run_plain_points_the_process_itself_at_the_home_and_copies_app_support_by_default(tmp_path):
    src = tmp_path / "src"
    (src / "Library" / "Application Support" / "VideoScan").mkdir(parents=True)
    p, got = _run(tmp_path, ["--plain"], source=src)
    assert p.returncode == 0, p.stderr
    home = got["HOME"]
    assert home != "/Users/the-real-home" and got["CFFIXED_USER_HOME"] == home and got["owner"], got
    assert got["VIDEOSCAN_TEST_TMP"] == home + "/tmp/" and got["TEST_RUNNER_HOME"] is None
    assert got["app"], "a copy of App Support by default"
    assert not Path(home).exists()


def test_a_stopped_run_frees_its_home_and_stops_its_child(tmp_path):
    marker = tmp_path / "home.txt"
    child = f"import os, time; open({str(marker)!r}, 'w').write(os.environ['TEST_RUNNER_HOME']); time.sleep(60)"
    p = _subprocess.Popen([sys.executable, str(SCRIPT), "run", "--empty", "--", sys.executable, "-c", child],
                          stderr=_subprocess.PIPE, start_new_session=True)
    for _ in range(200):
        if marker.exists() and marker.read_text():
            break
        _time.sleep(0.05)
    home = Path(marker.read_text())
    assert home.is_dir()
    os.kill(p.pid, _signal.SIGTERM)                          # the wrapper only, as a lane's watchdog would
    assert p.wait(30) == 128 + _signal.SIGTERM
    assert not home.exists(), "a stopped run left its sealed home behind"


def test_run_without_a_command_is_a_usage_error(tmp_path):
    p = _subprocess.run([sys.executable, str(SCRIPT), "run", "--"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 2 and "usage" in p.stderr
