"""Sandbox tests for install_videoscan_dev_dependencies/migrate_data.sh (codex #122).

Two fake homes stand in for the two Macs. `ssh` is stubbed to run the remote
command inside the SOURCE home; rsync really runs (Homebrew rsync required);
`pgrep` and `defaults` are stubbed so the tests never see the real app or prefs.
"""
import hashlib
import os
import shutil
import sqlite3
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "install_videoscan_dev_dependencies" / "migrate_data.sh"
pytestmark = pytest.mark.skipif(
    not Path("/opt/homebrew/bin/rsync").exists(), reason="needs Homebrew rsync"
)


def _sandbox(tmp: Path, *, files_table=True, src_master="", stale_wal=False, hold_open=None):
    src, dst, bin_dir = tmp / "src", tmp / "dst", tmp / "bin"
    app = src / "Library/Application Support/VideoScan"
    dapp = dst / "Library/Application Support/VideoScan"
    for p in (app, dapp, bin_dir, src / "dev/VideoScan", dst / "dev/VideoScan"):
        p.mkdir(parents=True)
    table = "files" if files_table else "other"
    con = sqlite3.connect(app / "catalog.sqlite")
    con.execute("pragma journal_mode=wal")
    con.execute("pragma wal_autocheckpoint=0")
    con.execute(f"create table {table}(id)")
    con.execute("pragma user_version=12")
    con.commit()
    con.executemany(f"insert into {table} values(?)", [(i,) for i in range(7)])
    con.commit()
    # Snapshot db + hot WAL while the connection is open (as after a crash).
    shutil.copy(app / "catalog.sqlite", tmp / "c.db")
    shutil.copy(app / "catalog.sqlite-wal", tmp / "c.wal")
    con.close()
    shutil.copy(tmp / "c.db", app / "catalog.sqlite")
    shutil.copy(tmp / "c.wal", app / "catalog.sqlite-wal")
    (app / "catalog.sqlite-shm").unlink(missing_ok=True)
    (app / "catalog.cutover").write_text("cut")
    (app / "catalog.json").write_text("{}")
    fp = sqlite3.connect(app / "audio-fingerprints.sqlite")
    fp.execute("create table p(x)")
    fp.commit()
    if hold_open is None:
        fp.close()
    else:
        hold_open.append(fp)  # still open while the script runs
    if stale_wal:
        (dapp / "audio-fingerprints.sqlite-wal").write_text("STALE WAL FROM ANOTHER COPY")
    for repo in (src / "dev/VideoScan", dst / "dev/VideoScan"):
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / ".gitignore").write_text("photos/\n")
    (src / "dev/VideoScan/t.txt").write_text("x")
    subprocess.run(["git", "-C", str(src / "dev/VideoScan"), "add", "."], check=True)
    (src / "dev/VideoScan/photos").mkdir()
    (src / "dev/VideoScan/photos/a.jpg").write_text("img")
    os.utime(src / "dev/VideoScan/t.txt", (1, 1))  # stale stat: plain `git status` would rewrite the index
    (bin_dir / "ssh").write_text(
        "#!/bin/bash\n"
        'while [[ "$1" == -* ]]; do [[ "$1" == -o || "$1" == -e || "$1" == -l ]] && shift; shift; done\n'
        "shift\n"
        '[[ -n "$FAIL_ON" && "$*" == *"$FAIL_ON"* ]] && exit 255\n'
        f'cd "{src}" && exec /bin/bash -c "$*"\n'
    )
    (bin_dir / "pgrep").write_text("#!/bin/bash\nexit 1\n")
    (bin_dir / "defaults").write_text(
        f'#!/bin/bash\n[[ "$PWD" == "{src}" && -n "{src_master}" ]] && {{ echo "{src_master}"; exit 0; }}\nexit 1\n'
    )
    for f in bin_dir.iterdir():
        f.chmod(0o755)
    return src, dst, bin_dir


def _run(tmp, args, fail_on="", **kw):
    src, dst, bin_dir = _sandbox(tmp, **kw)
    index = src / "dev/VideoScan/.git/index"
    before = hashlib.sha256(index.read_bytes()).hexdigest()
    env = dict(os.environ, HOME=str(dst), PATH=f"{bin_dir}:{os.environ['PATH']}", FAIL_ON=fail_on)
    r = subprocess.run(["/bin/bash", str(SCRIPT), *args], env=env, capture_output=True, text=True, timeout=120)
    assert hashlib.sha256(index.read_bytes()).hexdigest() == before, "source .git/index was written"
    return r, src, dst


def test_dry_run_writes_nothing_on_either_side(tmp_path):
    r, src, dst = _run(tmp_path, ["--from", "m4"], stale_wal=True)
    assert r.returncode == 0, r.stdout + r.stderr
    dapp = dst / "Library/Application Support/VideoScan"
    assert sorted(p.name for p in dapp.iterdir()) == ["audio-fingerprints.sqlite-wal"]
    assert "would move a leftover audio-fingerprints.sqlite-wal" in r.stdout
    assert not (dst / "dev/VideoScan/photos").exists()


def test_go_copies_hot_wal_and_proves_it(tmp_path):
    r, src, dst = _run(tmp_path, ["--go", "--from", "m4"], stale_wal=True)
    assert r.returncode == 0, r.stdout + r.stderr
    dapp = dst / "Library/Application Support/VideoScan"
    assert "byte-identical" in r.stdout and "catalog files rows: 7" in r.stdout  # 7 rows live only in the WAL
    # F1: the stale WAL beside a different audio-fingerprints.sqlite was moved aside, not paired.
    assert not (dapp / "audio-fingerprints.sqlite-wal").exists()
    assert any(p.name.startswith("audio-fingerprints.sqlite-wal.pre-migrate-") for p in dapp.iterdir())
    assert not (dapp / "catalog.sqlite-shm").exists()  # checks ran on a scratch copy
    assert (dst / "dev/VideoScan/photos/a.jpg").read_text() == "img"


def test_catalog_without_files_table_fails(tmp_path):  # F3
    r, *_ = _run(tmp_path, ["--go", "--from", "m4"], files_table=False)
    assert r.returncode == 1
    assert "could not count catalog files" in r.stdout and "FAILED THE CHECK" in r.stderr


def test_ssh_failure_listing_ignored_files_aborts(tmp_path):  # F4
    r, _, dst = _run(tmp_path, ["--go", "--from", "m4"], fail_on="git --no-optional-locks")
    assert r.returncode == 1 and "could not list the ignored files" in r.stderr
    assert not (dst / "dev/VideoScan/photos").exists()


def test_masters_disagree_is_not_success(tmp_path):  # F5
    r, *_ = _run(tmp_path, ["--go", "--from", "m4"], src_master="RicksUltra.local")
    assert r.returncode == 3 and "THEY DISAGREE" in r.stderr


def test_database_open_on_source_refuses(tmp_path):  # F1: lsof, not just pgrep
    held = []
    try:
        r, _, dst = _run(tmp_path, ["--go", "--from", "m4"], hold_open=held)
    finally:
        for c in held:
            c.close()
    assert r.returncode == 1 and "a database in App Support is open on m4" in r.stderr
    assert not (dst / "Library/Application Support/VideoScan/catalog.sqlite").exists()
