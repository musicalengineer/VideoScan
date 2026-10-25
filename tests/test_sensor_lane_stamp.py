"""scripts/sensor_lane_stamp.sh — the GREEN stamp the pre-push hook reads.

Regression (2026-10-25): run_sensors.sh built its scratch index with `mktemp`,
which creates an EMPTY file; git refuses a zero-length index ("index file
smaller than expected"), `git add` failed, the tree hash came back empty and
the stamp was silently skipped — so no push to main passed the hook from the
day it landed (10/23). RED on the extracted-but-unfixed script; GREEN after
the fix. Pins: the stamp lands in the COMMON git dir (a worktree stamps the
main repository's file), covers untracked files, keeps 50 lines, and a
failure is loud and non-zero.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "sensor_lane_stamp.sh"


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True).stdout.strip()


def make_repo(d: Path) -> Path:
    r = d / "repo"
    r.mkdir()
    git(r, "init", "-q")
    git(r, "config", "user.email", "t@t"); git(r, "config", "user.name", "t")
    (r / "f.txt").write_text("x\n")
    git(r, "add", "f.txt"); git(r, "commit", "-qm", "init")
    return r


class Stamp(unittest.TestCase):
    def test_a_green_run_stamps_the_working_tree_including_untracked_files(self):
        with tempfile.TemporaryDirectory() as d:
            r = make_repo(Path(d))
            (r / "new.txt").write_text("untracked but not ignored\n")
            out = subprocess.run(["bash", str(SCRIPT), str(r)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("sensor lane stamp: tree ", out.stdout)
            stamp = r / ".git" / "sensor-lane-green"
            self.assertTrue(stamp.exists(), "the stamp file the pre-push hook reads")
            stamped = stamp.read_text().split()[0]
            git(r, "add", "-A"); git(r, "commit", "-qm", "with new")
            self.assertEqual(stamped, git(r, "rev-parse", "HEAD^{tree}"), "the stamp names the tree a commit of this tree would have")
            self.assertEqual(git(r, "status", "--short"), "", "the real index was never touched (clean after the commit)")

    def test_a_worktree_stamps_the_common_git_dir(self):
        with tempfile.TemporaryDirectory() as d:
            r = make_repo(Path(d))
            wt = Path(d) / "wt"
            git(r, "worktree", "add", "-q", "-b", "side", str(wt))
            out = subprocess.run(["bash", str(SCRIPT), str(wt)], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertTrue((r / ".git" / "sensor-lane-green").exists(), "the main repo's file, where the hook looks")


    def test_tracked_but_ignored_files_stay_in_the_stamped_tree(self):
        """2026-10-25 (second flaw): the scratch index started EMPTY, so `git add -A` skipped
        tracked files that also match .gitignore, and the stamp never equalled the commit's
        tree — the pre-push hook refused main even after the empty-index fix."""
        with tempfile.TemporaryDirectory() as d:
            r = make_repo(Path(d))
            (r / "kept.log").write_text("tracked\n")
            git(r, "add", "kept.log"); git(r, "commit", "-qm", "track a log")
            (r / ".gitignore").write_text("*.log\n")
            git(r, "add", ".gitignore"); git(r, "commit", "-qm", "then ignore logs")
            subprocess.run(["bash", str(SCRIPT), str(r)], capture_output=True, text=True, check=True)
            stamped = (r / ".git" / "sensor-lane-green").read_text().split()[0]
            self.assertEqual(stamped, git(r, "rev-parse", "HEAD^{tree}"), "the tree a commit of this working tree has")

    def test_fifty_lines_are_kept(self):
        with tempfile.TemporaryDirectory() as d:
            r = make_repo(Path(d))
            stamp = r / ".git" / "sensor-lane-green"
            stamp.write_text("".join(f"{i:040x} 2026-01-01T00:00:00Z\n" for i in range(60)))
            subprocess.run(["bash", str(SCRIPT), str(r)], capture_output=True, text=True, check=True)
            lines = stamp.read_text().splitlines()
            self.assertEqual(len(lines), 50)
            self.assertTrue(lines[-1].startswith(git(r, "rev-parse", "HEAD^{tree}")))

    def test_not_a_repo_is_loud_and_nonzero(self):
        with tempfile.TemporaryDirectory() as d:
            out = subprocess.run(["bash", str(SCRIPT), d], capture_output=True, text=True)
            self.assertNotEqual(out.returncode, 0)
            self.assertIn("NOT recorded", out.stderr)


if __name__ == "__main__":
    unittest.main()
