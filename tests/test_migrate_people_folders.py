"""scripts/migrate_people_folders.py — recovery protocol (codex #1710, 2026-09-23).

Two source-confirmed limitations of the People/ folder migration:

  1. The file was MOVED before its manifest line was written, and the line
     was only flushed (a Python buffer flush is not a durable write). A crash
     between the two left a moved file the undo manifest never heard of.
  2. Undo trusted PATHS: if the recorded destination had since been replaced
     or reused, undo moved the replacement into the original person's folder
     as though it were the migrated file.

Every test runs in a pytest tmp_path sandbox — never the real archive or
Rick's real People folders. Nothing here touches /Volumes.
"""
import importlib.util
import json
import os
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts" / "migrate_people_folders.py"
SPEC = importlib.util.spec_from_file_location("migrate_people_folders", PATH)
mpf = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = mpf
SPEC.loader.exec_module(mpf)


def people(tmp_path):
    root = tmp_path / "People"
    src = root / "Mary_OConnor"
    dst = root / "Mary_Christina_O_Connor_G89Q-34N"
    src.mkdir(parents=True)
    (src / "portrait.jpg").write_bytes(b"the real portrait of grandma")
    (src / "letter.txt").write_bytes(b"a letter")
    return root, src, dst


def run_move(src, dst, manifest_path):
    manifest = []
    with open(manifest_path, "w") as log:
        mpf.move_folder(str(src), str(dst), manifest, log)
    return manifest


# ------------------------------------------------------------ journal first

def test_the_journal_entry_is_durable_before_the_file_moves(tmp_path, monkeypatch):
    """RED on the old order: shutil.move ran first, so at the moment of the
    move the manifest on disk did not name the file."""
    _root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "people-migration-test.jsonl"
    fsynced = []
    real_fsync = os.fsync
    monkeypatch.setattr(mpf.os, "fsync", lambda fd: (fsynced.append(fd), real_fsync(fd))[1])
    real_move = mpf.shutil.move
    seen_at_move = []

    def checking_move(a, b):
        on_disk = [json.loads(l) for l in open(manifest_path) if l.strip()]
        seen_at_move.append((a, [e.get("from") for e in on_disk], list(fsynced)))
        return real_move(a, b)

    monkeypatch.setattr(mpf.shutil, "move", checking_move)
    manifest = run_move(src, dst, manifest_path)

    assert len(seen_at_move) == 2
    for moving, journaled, fsyncs in seen_at_move:
        assert moving in journaled, f"{moving} moved before the manifest named it"
        assert fsyncs, "the manifest line was not fsync'd before the move"
    assert all("identity" in e for e in manifest if "from" in e)


def test_an_interrupted_run_is_still_fully_reversible(tmp_path, monkeypatch):
    """Crash immediately after the first move: the manifest names it, and
    undo puts it back; the second file (journaled? no — never reached) is
    untouched."""
    root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "m.jsonl"
    real_move = mpf.shutil.move
    calls = []

    def crash_after_first(a, b):
        real_move(a, b)
        calls.append(a)
        raise KeyboardInterrupt("power cut")

    monkeypatch.setattr(mpf.shutil, "move", crash_after_first)
    with pytest.raises(KeyboardInterrupt):
        run_move(src, dst, manifest_path)
    monkeypatch.setattr(mpf.shutil, "move", real_move)

    moved = pathlib.Path(calls[0])
    assert not moved.exists()
    result = mpf.undo(str(manifest_path))
    assert result["restored"] == 1
    assert moved.exists()
    assert sorted(p.name for p in src.iterdir()) == ["letter.txt", "portrait.jpg"]


def test_journaled_but_never_moved_is_reported_not_missing(tmp_path, monkeypatch):
    """Crash between the journal write and the move: the file is still at
    its origin, provably the same file — nothing to do, and it says so."""
    _root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "m.jsonl"

    def crash(a, b):
        raise KeyboardInterrupt("power cut before the rename")

    monkeypatch.setattr(mpf.shutil, "move", crash)
    with pytest.raises(KeyboardInterrupt):
        run_move(src, dst, manifest_path)
    monkeypatch.undo()
    result = mpf.undo(str(manifest_path))
    assert result == {"restored": 0, "dirs": 0, "never_moved": 1, "missing": 0,
                      "blocked": 0, "replaced": 0, "unverified": 0}


# ------------------------------------------------------------ identity-verified undo

def test_undo_restores_genuine_moves(tmp_path):
    _root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "m.jsonl"
    run_move(src, dst, manifest_path)
    assert not src.exists(), "the emptied source folder is removed"
    result = mpf.undo(str(manifest_path))
    assert result["restored"] == 2 and result["dirs"] == 1
    assert (src / "portrait.jpg").read_bytes() == b"the real portrait of grandma"


def test_undo_never_moves_a_replacement_into_the_original_folder(tmp_path):
    """RED on the old undo: it checked only that the path existed, so a
    different file now sitting at the destination was moved 'back' into
    Mary's folder under the original name."""
    _root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "m.jsonl"
    run_move(src, dst, manifest_path)
    # Since the migration, the portrait was replaced by a different photo
    # under the same name (the app's chosen-photo writer, or Finder).
    (dst / "portrait.jpg").write_bytes(b"a DIFFERENT photo, same name, same folder")

    result = mpf.undo(str(manifest_path))

    assert result["replaced"] == 1
    assert not (src / "portrait.jpg").exists(), \
        "undo moved a replacement into the original person's folder"
    assert (dst / "portrait.jpg").read_bytes() == b"a DIFFERENT photo, same name, same folder"
    assert (src / "letter.txt").read_bytes() == b"a letter", "the genuine one still goes back"


def test_same_size_replacement_is_still_caught(tmp_path):
    """Size alone is not identity: the digest catches a same-length swap."""
    _root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "m.jsonl"
    run_move(src, dst, manifest_path)
    original = (dst / "letter.txt").read_bytes()
    (dst / "letter.txt").write_bytes(b"x" * len(original))
    result = mpf.undo(str(manifest_path))
    assert result["replaced"] == 1
    assert not (src / "letter.txt").exists()


def test_a_legacy_manifest_is_not_trusted_by_default(tmp_path):
    """A manifest written before identities were recorded (the historical
    56-file run's shape) cannot prove anything: left alone and reported;
    --trust-unverified restores the old by-path behaviour on request."""
    root, src, dst = people(tmp_path)
    dst.mkdir(parents=True)
    entries = []
    for name in ("portrait.jpg", "letter.txt"):
        os.rename(src / name, dst / name)
        entries.append({"from": str(src / name), "to": str(dst / name)})
    manifest_path = tmp_path / "legacy.jsonl"
    manifest_path.write_text("".join(json.dumps(e) + "\n" for e in entries))

    result = mpf.undo(str(manifest_path))
    assert result["unverified"] == 2 and result["restored"] == 0
    assert (dst / "portrait.jpg").exists()

    result = mpf.undo(str(manifest_path), trust_unverified=True)
    assert result["restored"] == 2
    assert (src / "portrait.jpg").exists()


def test_undo_still_never_overwrites_the_origin(tmp_path):
    _root, src, dst = people(tmp_path)
    manifest_path = tmp_path / "m.jsonl"
    run_move(src, dst, manifest_path)
    src.mkdir()
    (src / "portrait.jpg").write_bytes(b"something new put here since")
    result = mpf.undo(str(manifest_path))
    assert result["blocked"] == 1
    assert (src / "portrait.jpg").read_bytes() == b"something new put here since"


def test_identity_of_a_subfolder_covers_its_contents(tmp_path):
    d = tmp_path / "album"
    d.mkdir()
    (d / "a.jpg").write_bytes(b"1")
    first = mpf.identity(str(d))
    assert first["kind"] == "dir"
    (d / "a.jpg").write_bytes(b"2")
    assert mpf.identity(str(d)) != first
    assert mpf.identity(str(tmp_path / "nope")) is None
