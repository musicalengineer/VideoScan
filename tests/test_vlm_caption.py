#!/usr/bin/env python3
"""Sanity smoke test for scripts/vlm_caption.py.

Runs the captioner against the small fixture clip with --frames 2 and
verifies the JSON output is shaped the way the catalog integration
will expect (timestamped frames, non-empty captions, model id recorded).

Skipped automatically when the optional MLX stack isn't installed
(no venv-mlx) or ffmpeg/ffprobe aren't on PATH — keeps CI green on
machines that don't carry the MLX dependencies.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "tests/fixtures/videos/test_face_3s.mp4"
VENV_MLX_PYTHON = REPO_ROOT / "venv-mlx/bin/python"


def _mlx_env_available() -> bool:
    if not VENV_MLX_PYTHON.exists():
        return False
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        return False
    if not FIXTURE.exists():
        return False
    return True


@unittest.skipUnless(
    _mlx_env_available(),
    "venv-mlx, ffmpeg/ffprobe, or fixture missing — skipping MLX smoke",
)
class VlmCaptionSmoke(unittest.TestCase):
    def test_captions_two_frames_and_emits_expected_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_path = Path(tmp) / "captions.json"
            env = os.environ.copy()
            env["PATH"] = f"/opt/homebrew/bin:{env.get('PATH', '')}"
            result = subprocess.run(
                [
                    str(VENV_MLX_PYTHON),
                    "scripts/vlm_caption.py",
                    str(FIXTURE),
                    "--frames", "2",
                    "--max-tokens", "40",
                    "--out", str(out_path),
                ],
                cwd=str(REPO_ROOT),
                env=env,
                capture_output=True,
                text=True,
                timeout=600,
            )
            self.assertEqual(
                result.returncode, 0,
                msg=f"captioner failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
            self.assertTrue(out_path.exists(), "expected JSON output file")

            payload = json.loads(out_path.read_text())
            self.assertEqual(payload["video"], str(FIXTURE))
            self.assertIn("qwen", payload["model"].lower())
            self.assertGreater(payload["duration_s"], 0.0)

            frames = payload["frames"]
            self.assertEqual(len(frames), 2)
            for f in frames:
                self.assertIn("timestamp", f)
                self.assertIn("caption", f)
                self.assertGreater(f["timestamp"], 0.0)
                self.assertLess(f["timestamp"], payload["duration_s"])
                self.assertTrue(f["caption"].strip(), "caption should be non-empty")

            timestamps = [f["timestamp"] for f in frames]
            self.assertEqual(timestamps, sorted(timestamps), "frames should be ordered")


if __name__ == "__main__":
    unittest.main()
