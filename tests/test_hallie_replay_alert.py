"""The session banner's Hallie replay line (2026-11-15).

Regression: the nightlies of 11/05, 11/06 and 11/15 replayed nothing (Ollama
was down) and nothing said so — the nightly row stayed status=ok.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import hallie_replay_alert as alert  # noqa: E402

DOWN = ("hallie replay failed before any lane: host http://127.0.0.1:11434 did not answer /api/tags "
        "(or lists no models); wanted model qwen3.8:27b-mlx (documented brain (app setting unset))")
OK = "hallie replay ok: strict 56/56 pass, 0 fail, 0 incomplete; advisory 670/826 pass, 156 fail (advisory); 721s"


def night(logs: Path, stamp: str, replay: str | None) -> None:
    (logs / f"nightly_test_{stamp}.log").write_text("[02:00:05] === Nightly local test run starting ===\n")
    if replay is not None:
        (logs / f"nightly_test_{stamp}.log.hallie-replay").write_text(replay)


def test_the_real_line_of_2026_11_15_is_red(tmp_path):
    night(tmp_path, "20261114_020005", OK + "\n")
    night(tmp_path, "20261115_020005", DOWN + "\n")
    line = alert.alert(tmp_path)
    assert line.startswith("🔴 Hallie replay, nightly of 2026-11-15: failed before any lane: host http://127.0.0.1:11434 did not answer")
    assert "qwen3.8:27b-mlx" in line


def test_an_ok_replay_is_silent_even_after_a_bad_night(tmp_path):
    night(tmp_path, "20261115_020005", DOWN + "\n")
    night(tmp_path, "20261116_020005", OK + "\n")
    assert alert.alert(tmp_path) == ""


def test_strict_failures_and_incomplete_runs_are_red(tmp_path):
    night(tmp_path, "20261103_020005", "hallie replay failed: strict 52/56 pass, 4 fail, 0 incomplete; advisory 622/826 pass, 204 fail (advisory); 2186s\n")
    assert "strict 52/56 pass, 4 fail" in alert.alert(tmp_path)
    night(tmp_path, "20261104_020004", "hallie replay incomplete: strict 0/56 pass, 0 fail, 56 incomplete; advisory 0/826 pass, 0 fail (incomplete); 2s\n")
    assert alert.alert(tmp_path).startswith("🔴 Hallie replay, nightly of 2026-11-04: incomplete: strict 0/56")


def test_a_nightly_with_no_replay_file_or_no_verdict_is_red(tmp_path):
    night(tmp_path, "20261115_020005", None)
    assert alert.alert(tmp_path) == "🔴 Hallie replay left no verdict in the nightly of 2026-11-15 (it did not run, or was cut off)"
    # Cut off after the runner's progress lines: those are not a verdict.
    night(tmp_path, "20261116_020005", "hallie replay: http://127.0.0.1:11434 was down — started /opt/homebrew/bin/ollama serve\n"
                                       "hallie replay: qwen3.8:27b-mlx is loaded on http://127.0.0.1:11434 (41s)\n")
    assert "left no verdict in the nightly of 2026-11-16" in alert.alert(tmp_path)


def test_progress_lines_before_an_ok_verdict_do_not_hide_it(tmp_path):
    night(tmp_path, "20261116_020005", "hallie replay: http://127.0.0.1:11434 was down — started /opt/homebrew/bin/ollama serve\n"
                                       "hallie replay: qwen3.8:27b-mlx is loaded on http://127.0.0.1:11434 (41s)\n" + OK + "\n")
    assert alert.alert(tmp_path) == ""


def test_nonsense_never_raises_and_a_long_line_is_cut(tmp_path):
    assert alert.alert(tmp_path) == ""                      # a host with no nightly: silent
    night(tmp_path, "garbage", "\x00\xff not a verdict\n")
    assert "left no verdict in the nightly of garbage" in alert.alert(tmp_path)
    night(tmp_path, "zz_long", "hallie replay failed: " + "x" * 5000 + "\n")
    assert len(alert.alert(tmp_path)) < 400


def test_the_command_exits_zero_and_the_banner_calls_it(tmp_path):
    night(tmp_path, "20261115_020005", DOWN + "\n")
    proc = subprocess.run([sys.executable, str(REPO / "scripts/hallie_replay_alert.py"), "--logs", str(tmp_path)],
                          capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0 and proc.stdout.startswith("🔴 Hallie replay, nightly of 2026-11-15")
    missing = subprocess.run([sys.executable, str(REPO / "scripts/hallie_replay_alert.py"), "--logs", str(tmp_path / "none")],
                             capture_output=True, text=True, timeout=30)
    assert missing.returncode == 0 and missing.stdout == ""
    hook = (REPO / ".claude/scripts/session_start.sh").read_text()
    assert 'scripts/hallie_replay_alert.py' in hook
