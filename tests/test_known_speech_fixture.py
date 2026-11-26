"""tests/known_speech_fixture.py: a stalled `say` never hangs the lane (#490).

2026-11-18: three script-tests lanes at once; in each, `say -o … known_speech_<shape>.speech.aiff`
sat 13-38 minutes with no output while the same command by hand finished in 1.1 s, and the
lane ended RED at script_tests_lane.py's 3600 s watchdog. The fixture now gives `say` a
timeout and one retry, and synthesises the sentence once per process (the media matrix
asked `say` six times). No real `say` or ffmpeg here: subprocess.run is replaced."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import known_speech_fixture as ks  # noqa: E402


class FakeRun:
    """Stands in for subprocess.run: `say -v ?` lists no voices, `say -o` stalls the first
    `stalls` times then writes the AIFF, ffmpeg succeeds and writes the clip."""

    def __init__(self, stalls: int):
        self.stalls, self.says, self.timeouts = stalls, 0, []

    def __call__(self, argv, **kw):
        if argv[:2] == ["/usr/bin/say", "-v"] and argv[2] == "?":
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
        if argv[0] == "/usr/bin/say":
            self.says += 1
            self.timeouts.append(kw.get("timeout"))
            if self.stalls:
                self.stalls -= 1
                raise subprocess.TimeoutExpired(argv, kw.get("timeout") or 0)
            Path(argv[argv.index("-o") + 1]).write_bytes(b"FORM-aiff")
            return subprocess.CompletedProcess(argv, 0, stdout=b"", stderr=b"")
        Path(argv[-1]).write_bytes(b"clip")
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")


@pytest.fixture
def fake(monkeypatch):
    def install(stalls):
        run = FakeRun(stalls)
        monkeypatch.setattr(ks.subprocess, "run", run)
        monkeypatch.setattr(ks, "tool", lambda name: "/usr/bin/true")
        monkeypatch.setattr(ks, "_SPEECH", {}, raising=False)
        return run
    return install


def test_say_has_a_timeout_and_one_stall_is_retried(fake, tmp_path):
    run = fake(stalls=1)
    assert ks.make_known_speech(tmp_path / "a.mov") == "default"
    assert run.says == 2
    assert all(t is not None and t <= 60 for t in run.timeouts), run.timeouts
    assert (tmp_path / "a.mov").read_bytes() == b"clip"


def test_two_stalls_end_in_seconds_with_the_cause_named(fake, tmp_path):
    fake(stalls=2)
    with pytest.raises(ks.SpeechStalled, match="speech synthesis stalled"):
        ks.make_known_speech(tmp_path / "a.mov")


def test_the_sentence_is_synthesised_once_per_process(fake, tmp_path):
    run = fake(stalls=0)
    for shape, (ext, _, _) in ks.SHAPES.items():
        ks.make_known_speech(tmp_path / f"k_{shape}.{ext}", shape)
    assert run.says == 1, "the media matrix asked `say` once per shape"
    assert not list(tmp_path.glob("*.speech.aiff")), "the per-clip AIFF is still removed"
