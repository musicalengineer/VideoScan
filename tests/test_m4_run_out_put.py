"""scripts/m4_run.sh: summary.txt and the testbed block never follow a planted link (#486).

The run folder is new and the run's own, but the lanes run inside it for hours; a link planted at
summary.txt (or testbed-block.txt, summary.txt.new) was written THROUGH by plain `>>` / `>`
redirections. They now go through out_put, the same rule as the run's logs (Codex #315-2): never
through a link, never a file with a second name. The helper is extracted from the script and run
as it is; nothing here starts a lane."""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "m4_run.sh"


def helper() -> str:
    text = SCRIPT.read_text()
    m = re.search(r"^# >>> out_put\n(.*?)^# <<< out_put$", text, re.M | re.S)
    if not m:
        raise AssertionError("m4_run.sh has no out_put helper between its markers")
    return m.group(1)


def out_put(*args: str, data: str = "") -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", helper() + '\nout_put "$@"', "out_put", *args], input=data,
                          capture_output=True, text=True, timeout=60)


class OutPutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.outside = self.d / "outside.txt"
        self.outside.write_text("family\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_summary_or_block_write_is_a_plain_redirection(self):
        text = SCRIPT.read_text()
        for pattern in (r'>>\s*"\$OUT/summary\.txt"', r'[^>]>\s*"\$OUT/summary\.txt', r'>\s*"\$OUT/testbed-block\.'):
            self.assertEqual(re.findall(pattern, text), [], pattern)

    def test_append_and_replace_a_plain_file(self):
        f = self.d / "summary.txt"
        self.assertEqual(out_put(str(f), data="one\n").returncode, 0)
        self.assertEqual(out_put(str(f), data="two\n").returncode, 0)
        self.assertEqual(f.read_text(), "one\ntwo\n")
        self.assertEqual(out_put(str(f), "replace", data="three\n").returncode, 0)
        self.assertEqual(f.read_text(), "three\n")
        self.assertEqual(out_put(str(f), "cat").stdout, "three\n")
        self.assertEqual(out_put(str(self.d / "new.txt"), data="x\n").returncode, 0, "a missing file is created")

    def test_a_planted_link_is_never_written_or_read_through(self):
        link = self.d / "summary.txt"
        link.symlink_to(self.outside)
        p = out_put(str(link), data="planted\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("refused", p.stderr)
        self.assertEqual(self.outside.read_text(), "family\n")
        self.assertEqual(out_put(str(link), "cat").stdout, "")
        # replace swaps the NAME for a new file of ours; the link's target is untouched
        self.assertEqual(out_put(str(link), "replace", data="ours\n").returncode, 0)
        self.assertFalse(link.is_symlink())
        self.assertEqual(link.read_text(), "ours\n")
        self.assertEqual(self.outside.read_text(), "family\n")

    def test_a_second_name_or_a_folder_is_refused_and_left_as_it_was(self):
        hard = self.d / "testbed-block.txt"
        os.link(self.outside, hard)
        self.assertNotEqual(out_put(str(hard), data="x\n").returncode, 0)
        self.assertNotEqual(out_put(str(hard), "cat").returncode, 0)
        self.assertEqual(self.outside.read_text(), "family\n")
        # replace gives the NAME a new file; the other name keeps its bytes
        self.assertEqual(out_put(str(hard), "replace", data="x\n").returncode, 0)
        self.assertEqual(self.outside.read_text(), "family\n")
        folder = self.d / "summary.txt.new"
        folder.mkdir()
        self.assertNotEqual(out_put(str(folder), "replace", data="x\n").returncode, 0)
        self.assertTrue(folder.is_dir())
        target = self.d / "dir"
        target.mkdir()
        dlink = self.d / "s2.txt"
        dlink.symlink_to(target)
        self.assertEqual(out_put(str(dlink), "replace", data="x\n").returncode, 0)
        self.assertEqual(list(target.iterdir()), [], "nothing was moved into the folder a link named")


if __name__ == "__main__":
    unittest.main()
